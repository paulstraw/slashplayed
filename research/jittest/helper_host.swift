// The host side of the on-device JIT helper: SPJitTest starts its own bundled classic extension
// (PlugIns/SPJitHelper.appex, apps/client/helper/Helper.swift) as a separate process and sends it requests. Two
// processes because a process can't service its own debugger stops: the app sits in `brk #0xf00d` while
// the helper, attached to it, does the prepare.
//
// No public API starts an app's own classic extension, so this uses NSExtension's private class
// (ExtensionFoundation), the calls LiveContainer uses for LiveProcess: look the extension up by its bundle
// ID, begin a request with input items, and take the reply items in the completion block. Looking it up
// by bundle ID also survives a sideloader renaming the app.
//
// main.c is C, so this exposes plain C entry points and logs through a function pointer into main.c's
// say() (stdout and Documents/spjit.log).
import Foundation
import Network

typealias SPLog = @convention(c) (UnsafePointer<CChar>) -> Void

#if !SP_IDEVICE  // with idevice, apps/client/helper/Device.swift (linked in for P1) has the same one
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
#endif

// One log sink for both the host's own lines and the helper's, which come back with its reply.
final class HostLog: @unchecked Sendable {
    let out: SPLog
    let t0 = now()
    init(_ out: SPLog) { self.out = out }
    func say(_ line: String) { out(String(format: "  [%6.3f] %@\n", now() - t0, line)) }
    func log(_ line: String) { say("helper: " + line) }
}

private final class Done: @unchecked Sendable {
    var code: Int32 = 1
    var finished = false
}

// Runs `body` to completion while pumping the main run loop instead of blocking it: main.c calls in on
// the main thread, and the extension's blocks may be delivered to the main queue, so a semaphore wait
// there could deadlock.
func runToCompletion(timeout: Double, _ log: HostLog, _ body: @escaping @Sendable () async -> Int32) -> Int32 {
    let done = Done()
    Task {
        let code = await body()
        DispatchQueue.main.async {
            done.code = code
            done.finished = true
        }
    }
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !done.finished && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    if !done.finished { log.say("timed out after \(Int(timeout)) s") }
    return done.finished ? done.code : 1
}

// A reply or a failure, whichever comes first, exactly once.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func callAsFunction() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

@objc private protocol SPNSExtensionClass {
    @objc(extensionWithIdentifier:error:)
    func `extension`(withIdentifier identifier: String) throws -> AnyObject
}

@objc private protocol SPNSExtension {
    @objc(beginExtensionRequestWithInputItems:completion:)
    func beginRequest(withInputItems items: [Any], completion: @escaping (NSUUID?) -> Void)
    @objc(pidForRequestIdentifier:)
    func pid(forRequestIdentifier identifier: NSUUID) -> Int32
    @objc(setRequestCompletionBlock:)
    func setRequestCompletionBlock(_ block: @escaping (NSUUID?, [Any]?) -> Void)
    @objc(setRequestCancellationBlock:)
    func setRequestCancellationBlock(_ block: @escaping (NSUUID?, NSError?) -> Void)
    @objc(setRequestInterruptionBlock:)
    func setRequestInterruptionBlock(_ block: @escaping (NSUUID?) -> Void)
}

// One request to the helper: starts it (a new process each time) with `request` as the input item's
// userInfo, and calls `done` once with the reply item's userInfo, or nil (logged) when the helper didn't
// answer. The helper's log lines are logged first.
private func helperBegin(_ request: [String: Any], _ log: HostLog,
                         _ done: @escaping @Sendable ([AnyHashable: Any]?) -> Void) {
    guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("SPJitHelper.appex"),
          let id = Bundle(url: url)?.bundleIdentifier else {
        log.say("no PlugIns/SPJitHelper.appex")
        return done(nil)
    }
    if NSClassFromString("NSExtension") == nil {
        dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW)
    }
    guard let cls = NSClassFromString("NSExtension") else {
        log.say("no NSExtension class")
        return done(nil)
    }
    let found: AnyObject
    do {
        found = try unsafeBitCast(cls as AnyObject, to: SPNSExtensionClass.self).extension(withIdentifier: id)
    } catch {
        log.say("extensionWithIdentifier \(id): \(error)")
        return done(nil)
    }
    let ext = unsafeBitCast(found, to: SPNSExtension.self)
    let t = now()
    let once = Once()
    // The blocks hold `found`: the NSExtension has to outlive the request.
    let finish: @Sendable ([AnyHashable: Any]?) -> Void = { reply in
        guard once() else { return }
        withExtendedLifetime(found) {}
        for line in reply?["log"] as? [String] ?? [] { log.log(line) }
        done(reply)
    }
    ext.setRequestCompletionBlock { _, items in
        log.say(String(format: "%@ reply after %.3f s", request["op"] as? String ?? "?", now() - t))
        finish((items?.first as? NSExtensionItem)?.userInfo ?? [:])
    }
    ext.setRequestCancellationBlock { _, error in
        log.say("cancelled: \(error.map { "\($0)" } ?? "no error")")
        finish(nil)
    }
    ext.setRequestInterruptionBlock { _ in
        log.say("interrupted")
        finish(nil)
    }
    let item = NSExtensionItem()
    item.userInfo = request
    ext.beginRequest(withInputItems: [item]) { uuid in
        guard let uuid else {
            log.say("the request didn't start")
            return finish(nil)
        }
        log.say(String(format: "started the helper for %@ as pid %d after %.3f s", request["op"] as? String ?? "?",
            ext.pid(forRequestIdentifier: uuid), now() - t))
    }
}

private func helperRequest(_ request: [String: Any], _ log: HostLog) async -> [AnyHashable: Any]? {
    await withCheckedContinuation { c in
        helperBegin(request, log) { nonisolated(unsafe) let reply = $0; c.resume(returning: reply) }
    }
}

private func documents() -> URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents") }

// The RemotePairing record, put in Documents/pairingFile.plist by research/jittest/push-pairing.sh. It's
// handed to the helper as bytes; only its size is ever logged.
func readPairing(_ log: HostLog) -> Data? {
    guard let data = try? Data(contentsOf: documents().appendingPathComponent("pairingFile.plist")) else {
        log.say("no pairing record at Documents/pairingFile.plist (research/jittest/push-pairing.sh puts it there)")
        return nil
    }
    log.say("pairing record: \(data.count) bytes")
    return data
}

// The developer disk image's cryptex files as research/jittest/push-ddi.sh placed them: Documents/DDI/
// files.txt lists their paths relative to Documents/DDI/Restore, version.txt names the Xcode they're from.
func readDDI(_ log: HostLog) -> [String: Data]? {
    let dir = documents().appendingPathComponent("DDI")
    guard let list = try? String(contentsOf: dir.appendingPathComponent("files.txt"), encoding: .utf8) else {
        log.say("no developer disk image at Documents/DDI (research/jittest/push-ddi.sh puts it there)")
        return nil
    }
    var files: [String: Data] = [:]
    for path in list.split(separator: "\n").map(String.init) where !path.isEmpty {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("Restore").appendingPathComponent(path)) else {
            log.say("developer disk image file missing: Documents/DDI/Restore/\(path)")
            return nil
        }
        files[path] = data
    }
    let version = (try? String(contentsOf: dir.appendingPathComponent("version.txt"), encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "version unknown"
    log.say("developer disk image: \(files.count) files, \(files.values.reduce(0) { $0 + $1.count }) bytes, \(version)")
    return files
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func with<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

// Where else the device's RemotePairing service might be, if 10.7.0.1:49152 fails (an early visionOS 27
// run saw it reset; on 27.0.1 it works): the device advertises its real port over Bonjour (_remotepairing._tcp): through LocalDevVPN,
// 10.7.0.1:<that port> reaches the device's own service (the VPN rewrites only IPv4), else the advertised
// address itself. Browsing needs Info.plist's NSBonjourServices, and iOS asks the user about local network
// access the first time, so it only runs when 10.7.0.1:49152 didn't work.
func bonjourEndpoints(_ log: HostLog, type: String = "_remotepairing._tcp") async -> [String] {
    let queue = DispatchQueue(label: "spjit.bonjour")
    let found = Locked<[NWEndpoint]>([])
    let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
    browser.browseResultsChangedHandler = { results, _ in found.with { $0 = results.map(\.endpoint) } }
    browser.stateUpdateHandler = { state in if case .failed(let e) = state { log.say("bonjour browse failed: \(e)") } }
    browser.start(queue: queue)
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    browser.cancel()
    var endpoints: [String] = []
    for service in found.with({ $0 }) {
        // Resolve by connecting (TCP only, nothing sent): the connection's path names the host and port.
        let conn = NWConnection(to: service, using: .tcp)
        let ready = Locked(false)
        conn.stateUpdateHandler = { state in if case .ready = state { ready.with { $0 = true } } }
        conn.start(queue: queue)
        for _ in 0..<40 where !ready.with({ $0 }) { try? await Task.sleep(nanoseconds: 50_000_000) }
        if ready.with({ $0 }), case .hostPort(let host, let port)? = conn.currentPath?.remoteEndpoint {
            // A link-local IPv6 address keeps its %interface: the helper's getaddrinfo needs the scope.
            let address = "\(host)"
            endpoints.append("10.7.0.1:\(port.rawValue)")
            endpoints.append(address.contains(":") ? "[\(address)]:\(port.rawValue)" : "\(address):\(port.rawValue)")
            log.say("bonjour: \(service) at \(address) port \(port.rawValue)")
        } else {
            log.say("bonjour: \(service) didn't resolve")
        }
        conn.cancel()
    }
    var seen = Set<String>()
    return endpoints.filter { seen.insert($0).inserted }
}

private struct Session {
    let pairing: Data
    let endpoints: [String]
}

// The tunnel's endpoint (10.7.0.1:49152, then what Bonjour finds), and with `mount` the developer disk
// image mounted if none is. The mount comes before the attach because debugserver is in the image; in the
// client that's after the early scene (the launch watchdog counts it), here (no UIKit) inside the 20 s.
private func openSession(_ log: HostLog, mount: Bool) async -> Session? {
    guard let pairing = readPairing(log) else { return nil }
    var endpoints = ["10.7.0.1:49152"]
    guard var status = await helperRequest(["op": "status", "pairing": pairing, "endpoints": endpoints], log) else {
        return nil
    }
    if status["ok"] as? Bool != true {
        log.say("status: \(status["summary"] ?? "?")")
        endpoints = await bonjourEndpoints(log)
        if endpoints.isEmpty { return nil }
        guard let again = await helperRequest(["op": "status", "pairing": pairing, "endpoints": endpoints], log) else {
            return nil
        }
        status = again
    }
    log.say("status: \(status["summary"] ?? "?")")
    guard status["ok"] as? Bool == true else { return nil }
    // The endpoint that worked goes first next time.
    if let used = status["endpoint"] as? String { endpoints = [used] + endpoints.filter { $0 != used } }
    if mount && status["mounted"] as? Bool != true {
        guard let files = readDDI(log),
              let reply = await helperRequest(["op": "mount", "pairing": pairing, "endpoints": endpoints, "ddi": files], log)
        else { return nil }
        log.say("mount: \(reply["summary"] ?? "?")")
        guard reply["ok"] as? Bool == true else { return nil }
    }
    return Session(pairing: pairing, endpoints: endpoints)
}

// Experiment h1: start the helper and take its reply. Passes when the reply comes from another process;
// logs whether the helper's sandbox reaches 10.7.0.1:49152 and gs.apple.com.
@_cdecl("sp_helper_ping")
func sp_helper_ping(_ out: SPLog) -> Int32 {
    let log = HostLog(out)
    log.say("host pid \(getpid())")
    return runToCompletion(timeout: 30, log) {
        guard let info = await helperRequest(["op": "ping"], log) else { return 1 }
        let pid = (info["pid"] as? Int).map(Int32.init) ?? -1
        log.say("helper pid \(pid), host pid \(getpid()) (\(pid != getpid() ? "two processes" : "SAME PROCESS"))")
        log.say("helper home: \(info["home"] ?? "?")")
        log.say("helper's connect to 10.7.0.1:49152: \(info["summary"] ?? "?")")
        log.say("helper's connect to gs.apple.com:80: \(info["gs"] ?? "?")")
        return pid > 0 && pid != getpid() ? 0 : 1
    }
}

// Experiment h2: the tunnel, and what the helper reports through it. Passes when the tunnel came up.
@_cdecl("sp_helper_status")
func sp_helper_status(_ out: SPLog) -> Int32 {
    let log = HostLog(out)
    return runToCompletion(timeout: 60, log) { await openSession(log, mount: false) == nil ? 1 : 0 }
}

// Experiment h5: misagent through the helper's tunnel, the device renewing its own profile (step 4,
// research/isideload). Installs Documents/spjit-profile.mobileprovision if it's there, else only lists.
// Passes when misagent answered (and the install, if any, added a profile).
@_cdecl("sp_helper_profiles")
func sp_helper_profiles(_ out: SPLog) -> Int32 {
    let log = HostLog(out)
    return runToCompletion(timeout: 90, log) {
        guard let session = await openSession(log, mount: false) else { return 1 }
        let path = NSHomeDirectory() + "/Documents/spjit-profile.mobileprovision"
        var request: [String: Any] = ["op": "profiles", "pairing": session.pairing, "endpoints": session.endpoints]
        if let profile = FileManager.default.contents(atPath: path) {
            request["install"] = [profile]
            log.say("installing \(path) (\(profile.count) bytes)")
        }
        guard let reply = await helperRequest(request, log) else { return 1 }
        log.say("profiles: \(reply["ok"] as? Bool == true ? "" : "FAIL: ")\(reply["summary"] ?? "?")")
        for p in reply["profiles"] as? [[String: Any]] ?? [] { log.say("  \(p["uuid"] ?? "?") \(p["appid"] ?? "?") until \(p["expires"] ?? "?")") }
        return reply["ok"] as? Bool == true ? 0 : 1
    }
}

nonisolated(unsafe) private var attachLog: HostLog?
nonisolated(unsafe) private var attachReply: (ok: Bool, summary: String)?

// H3 and H4, first half: open the session (mounting the image if needed), then ask the helper to attach
// to this process and service its requests. Returns once the request is sent; main.c then waits for
// P_TRACED like the shim and runs e4d or e7.
@_cdecl("sp_helper_attach")
func sp_helper_attach(_ out: SPLog) -> Int32 {
    let log = HostLog(out)
    attachLog = log
    return runToCompletion(timeout: 180, log) {
        guard let session = await openSession(log, mount: true) else { return 1 }
        let t = now()
        helperBegin(["op": "attach", "pid": Int(getpid()), "pairing": session.pairing,
                     "endpoints": session.endpoints], log) { info in
            let ok = info?["ok"] as? Bool == true
            let summary = info?["summary"] as? String ?? "no reply"
            // Logged here as well as in sp_helper_finish: if the app dies before that runs, this is the only trace.
            log.say(String(format: "attach reply after %.2f s: %@%@", now() - t, ok ? "" : "FAIL: ", summary))
            DispatchQueue.main.async { attachReply = (ok, summary) }
        }
        log.say("asked the helper to attach to pid \(getpid())")
        return 0
    }
}

// Second half: wait (up to 30 s) for the helper's reply, which comes once it has detached.
@_cdecl("sp_helper_finish")
func sp_helper_finish(_ out: SPLog) -> Int32 {
    let log = attachLog ?? HostLog(out)
    let deadline = Date(timeIntervalSinceNow: 30)
    while attachReply == nil && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    guard let reply = attachReply else {
        log.say("no reply from the helper after 30 s")
        return 1
    }
    log.say("helper: \(reply.ok ? "" : "FAIL: ")\(reply.summary)")
    return reply.ok ? 0 : 1
}
