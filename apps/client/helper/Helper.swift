// SPJitHelper.appex: the on-device JIT helper the device app bundles, a classic app extension (PlugIns/,
// NSExtensionPointIdentifier com.apple.ar.viewer), which the app's launcher starts by bundle ID with
// NSExtension's private request calls (apps/client/spjit.m; research/jittest/helper_host.swift in the
// experiments, which build this same source). A process can't service its own debugger stops, so this is
// the second process: attached to the app, it services the app's brk #0xf00d requests.
//
// Classic, not ExtensionKit: visionOS's installd refuses an extension on an extension point the app
// defines ("does not specify an Apple extension point"), so the helper claims Apple's AR viewer point, as
// LiveContainer's LiveProcess does. Nothing else ever starts it: its activation rule is FALSEPREDICATE.
//
// One request, one reply, both as the item's userInfo; each request is a new helper process. "op" picks
// the work:
//   "ping"   (h1) the helper's pid, and its TCP connects to the loopback VPN's RemotePairing endpoint and
//            to Apple's signing server.
//   "status" (h2) the tunnel (from "pairing" and "endpoints"): which endpoint worked, TXM, and the
//            mounted developer disk image, if any ("mounted").
//   "mount"  personalize and mount the disk image from "ddi" (paths relative to its Restore directory →
//            contents).
//   "attach" (h3, h4) attach to "pid" and service its requests; the reply comes once it has detached.
//   "profiles" (h5, research only: built with -D SP_MISAGENT and an idevice with misagent) lists the
//            device's provisioning profiles through misagent over RSD, installs "profile" if given, and
//            lists again: whether the device can renew its own profile (research/isideload, step 4).
//   "pair"   the headset only: pair-setup with visionOS's manual pairing service at "endpoints", the code
//            from the app over loopback ("pinPort", "pinToken"); the new record is the reply's "pairing"
//            (Pair.swift).
// The reply has "ok" and "summary", and the helper's log lines in "log", since there's no channel to
// stream them; "rejected" when the device didn't accept the pairing record. The pairing record is parsed
// in memory and never logged or written to disk.
import Foundation
#if SP_IDEVICE && SP_MISAGENT
import idevice  // the profiles op's misagent calls (below)
#endif

@objc(SPHelper)
final class SPHelper: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let request = (context.inputItems.first as? NSExtensionItem)?.userInfo ?? [:]
        DispatchQueue.global().async {
            var lines: [String] = []
            var reply: [String: Any] = ["pid": Int(getpid())]
            do {
                reply["summary"] = try SPHelper.handle(request, &reply, log: { lines.append($0) })
                reply["ok"] = true
            } catch {
                reply["ok"] = false
                reply["summary"] = "\(error)"
                if (error as? HelperError)?.rejected == true { reply["rejected"] = true }
            }
            reply["log"] = lines
            let item = NSExtensionItem()
            item.userInfo = reply
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }

    private static func handle(_ request: [AnyHashable: Any], _ reply: inout [String: Any],
                               log: (String) -> Void) throws -> String {
        let op = request["op"] as? String ?? "ping"
        if op == "ping" {
            reply["home"] = NSHomeDirectory()
            reply["gs"] = tcpProbe(host: "gs.apple.com", port: 80, timeoutMs: 5000)
            return tcpProbe(host: "10.7.0.1", port: 49152, timeoutMs: 3000)
        }
#if SP_IDEVICE
        if op == "pair" {
            // The code's listener keeps `log` only for the pairing's length.
            let data = try withoutActuallyEscaping(log) { log in
                try pair(endpoints: request["endpoints"] as? [String] ?? [],
                         pinPort: UInt16(truncatingIfNeeded: request["pinPort"] as? Int ?? 0),
                         pinToken: request["pinToken"] as? String ?? "", log: log)
            }
            reply["pairing"] = data
            return "paired: a \(data.count)-byte record"
        }
        let tunnel = try Tunnel.open(pairing: request["pairing"] as? Data ?? Data(),
            endpoints: request["endpoints"] as? [String] ?? [], log: log)
        reply["endpoint"] = tunnel.endpoint
        switch op {
        case "status":
            let txm = txmPresent().map { $0 ? "TXM" : "no TXM" } ?? "TXM unknown (registry unreadable)"
            let ddi = try mountedDDI(tunnel)
            reply["mounted"] = ddi != nil
            return "\(tunnel.endpoint), \(txm), developer disk image: \(ddi ?? "none mounted")"
        case "mount":
            return try mountDeveloperDiskImage(tunnel, files: request["ddi"] as? [String: Data] ?? [:], log: log)
        case "attach":
            return try serve(pid: Int32(request["pid"] as? Int ?? 0), tunnel: tunnel, log: log)
#if SP_MISAGENT
        case "profiles":
            return try profiles(tunnel, install: request["profile"] as? Data, log: log)
#endif
        default:
            throw HelperError("unknown op \(op)")
        }
#else
        throw HelperError("this helper was built without idevice: run scripts/build-idevice.sh, then build.sh")
#endif
    }
}

#if !SP_IDEVICE
struct HelperError: Error, CustomStringConvertible {
    let description: String
    let rejected = false
    init(_ description: String) { self.description = description }
}
#endif

// Connect only, no data: "connected", or the errno, with the time it took (a name is resolved first, IPv4).
// Non-blocking with a poll so an unrouted address can't hang the reply.
func tcpProbe(host: String, port: UInt16, timeoutMs: Int32) -> String {
    let t = DispatchTime.now().uptimeNanoseconds
    func took() -> String { String(format: "%.0f ms", Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6) }
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var info: UnsafeMutablePointer<addrinfo>?
    let gai = getaddrinfo(host, String(port), &hints, &info)
    guard gai == 0, let info else { return "resolve: \(String(cString: gai_strerror(gai))) after \(took())" }
    defer { freeaddrinfo(info) }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 { return "socket: errno \(errno) (\(String(cString: strerror(errno))))" }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    let r = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
    var err = r == 0 ? 0 : errno
    if err == EINPROGRESS {
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let n = poll(&p, 1, timeoutMs)
        if n == 0 { return "timed out after \(took())" }
        if n < 0 { return "poll: errno \(errno) (\(String(cString: strerror(errno))))" }
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
    }
    if err == 0 { return "connected in \(took())" }
    return "errno \(err) (\(String(cString: strerror(err)))) after \(took())"
}

#if SP_IDEVICE && SP_MISAGENT
// misagent through the tunnel's RSD (com.apple.misagent.shim.remote): the profile count, then the install.
// Profiles hold no secret (certificates and UDIDs are public to the team), but only counts and UUIDs are said.
func profiles(_ tunnel: Tunnel, install: Data?, log: (String) -> Void) throws -> String {
    var client: OpaquePointer?
    try check("misagent", misagent_connect_rsd(tunnel.adapter, tunnel.handshake, &client))
    defer { misagent_client_free(client) }
    func uuids() throws -> [String] {
        var profiles: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
        var lens: UnsafeMutablePointer<Int>?
        var count = 0
        try check("misagent copy", misagent_copy_all(client, &profiles, &lens, &count))
        defer { misagent_free_profiles(profiles, lens, count) }
        return (0..<count).compactMap { i in
            guard let p = profiles?[i], let n = lens?[i] else { return nil }
            let d = Data(bytes: p, count: n)
            guard let a = d.range(of: Data("<?xml".utf8)), let b = d.range(of: Data("</plist>".utf8)),
                  let plist = try? PropertyListSerialization.propertyList(from: d[a.lowerBound..<b.upperBound], format: nil)
                    as? [String: Any] else { return "?" }
            return plist["UUID"] as? String ?? "?"
        }
    }
    let before = try uuids()
    log("misagent: \(before.count) profiles installed")
    guard let install else { return "misagent reachable: \(before.count) profiles" }
    let t = now()
    try install.withUnsafeBytes { raw in
        try check("misagent install", misagent_install(client, raw.bindMemory(to: UInt8.self).baseAddress, install.count))
    }
    let after = try uuids()
    let added = Set(after).subtracting(before)
    log(String(format: "misagent: installed %d bytes in %.2f s", install.count, now() - t))
    return "misagent: \(before.count) profiles before, \(after.count) after, new: \(added.sorted().joined(separator: ", "))"
}
#endif
