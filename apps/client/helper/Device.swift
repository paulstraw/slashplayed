// The helper's real work, on idevice (scripts/build-idevice.sh builds it from source; build.sh
// compiles this file only when that library is there, with -D SP_IDEVICE): the RemotePairing tunnel to
// the device's own services through the loopback VPN, the developer disk image that debugserver comes
// from, and the debugger's side of our `brk #0xf00d` protocol.
#if SP_IDEVICE
import Foundation
import SPIOKit
import idevice

struct HelperError: Error, CustomStringConvertible {
    let description: String
    // From Tunnel.open: the device didn't accept the pairing record (it wanted pair-setup), so the record
    // is no good and a new one is needed. The reply says so ("rejected"), and the launcher deletes it.
    let rejected: Bool
    init(_ description: String, rejected: Bool = false) {
        self.description = description
        self.rejected = rejected
    }
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

// Turns an idevice error into a thrown one, freeing it.
func check(_ what: String, _ error: UnsafeMutablePointer<IdeviceFfiError>?) throws {
    guard let error else { return }
    let message = error.pointee.message.map { String(cString: $0) } ?? "no message"
    let text = "\(what): \(message) (code \(error.pointee.code), \(error.pointee.sub_code))"
    idevice_error_free(error)
    throw HelperError(text)
}

// What kind of pairing record this is, from its key names only (never a value): a RemotePairing record
// (identifier, Ed25519 keys, alt_irk; ~0.5 KB) or a lockdown pairing file (certificates; ~10 KB), which
// the RemotePairing service accepts a TCP connection for and then resets.
func pairingRecordKind(_ data: Data) -> String {
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let keys = (plist as? [String: Any]).map({ Set($0.keys) }) else { return "not a property list dictionary" }
    if keys.isSuperset(of: ["identifier", "private_key", "public_key"]) { return "RemotePairing" }
    if keys.contains("HostCertificate") || keys.contains("DeviceCertificate") { return "lockdown" }
    return "unknown (\(keys.count) keys)"
}

// The tunnel's pair-verify failing makes idevice fall back to pair-setup on the same connection, asking
// this for the PIN. We never pair from here (that's a credential the user makes once, deliberately), so
// note it and let the setup fail: idevice then uses a PIN that the device rejects.
nonisolated(unsafe) private var pairSetupAttempted = false
private let refusePin: @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? = { _ in
    pairSetupAttempted = true
    return nil
}

// A socket address for "host:port" (IPv4, or IPv6 in brackets, with a %scope if link-local).
func socketAddress(_ endpoint: String) -> (sockaddr_storage, socklen_t)? {
    guard let colon = endpoint.lastIndex(of: ":") else { return nil }
    let host = endpoint[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let port = String(endpoint[endpoint.index(after: colon)...])
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
    hints.ai_socktype = SOCK_STREAM
    var info: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, port, &hints, &info) == 0, let info else { return nil }
    defer { freeaddrinfo(info) }
    var storage = sockaddr_storage()
    withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: UnsafeRawBufferPointer(start: info.pointee.ai_addr,
        count: Int(info.pointee.ai_addrlen))) }
    return (storage, info.pointee.ai_addrlen)
}

// A RemotePairing tunnel and its RSD handshake: the way to every service on the device.
final class Tunnel {
    let adapter: OpaquePointer
    let handshake: OpaquePointer
    let endpoint: String

    private init(adapter: OpaquePointer, handshake: OpaquePointer, endpoint: String) {
        self.adapter = adapter
        self.handshake = handshake
        self.endpoint = endpoint
    }

    deinit {
        rsd_handshake_free(handshake)
        adapter_free(adapter)
    }

    // Tries each endpoint in turn; the error lists why each one failed.
    static func open(pairing: Data, endpoints: [String], log: (String) -> Void) throws -> Tunnel {
        let kind = pairingRecordKind(pairing)
        guard kind == "RemotePairing" else {
            throw HelperError("the pairing record is \(kind), not a RemotePairing record (\(pairing.count) bytes)")
        }
        var record: OpaquePointer?
        try pairing.withUnsafeBytes {
            try check("pairing record", rp_pairing_file_from_bytes($0.bindMemory(to: UInt8.self).baseAddress, UInt($0.count), &record))
        }
        defer { rp_pairing_file_free(record) }
        var failures: [String] = []
        var rejected = false
        for endpoint in endpoints {
            guard case (var address, let length)? = socketAddress(endpoint) else {
                failures.append("\(endpoint): not a numeric host:port")
                continue
            }
            var adapter: OpaquePointer?
            var handshake: OpaquePointer?
            pairSetupAttempted = false
            let t = now()
            let error = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing($0, length, "Slashplayed", record, refusePin, nil, &adapter, &handshake)
                }
            }
            do {
                try check(endpoint, error)
            } catch {
                failures.append("\(error)" + (pairSetupAttempted
                    ? " (the device didn't accept the pairing record, so idevice tried pair-setup)" : ""))
                rejected = rejected || pairSetupAttempted
                continue
            }
            guard let adapter, let handshake else {
                failures.append("\(endpoint): no tunnel returned")
                continue
            }
            log(String(format: "tunnel up through %@ in %.3f s", endpoint, now() - t))
            return Tunnel(adapter: adapter, handshake: handshake, endpoint: endpoint)
        }
        throw HelperError("no tunnel: " + failures.joined(separator: "; "), rejected: rejected)
    }
}

// TXM decides what may execute on M2-era and newer devices; without it, attaching alone (CS_DEBUGGED)
// would do. Informational only: the app asks for its prepare either way. nil if the registry can't be read.
func txmPresent() -> Bool? {
    let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen/memory-map")
    guard entry != 0 else { return nil }
    defer { IOObjectRelease(entry) }
    guard let keys = IORegistryEntryCreateCFProperty(entry, kIORegistryEntryPropertyKeysKey as CFString,
        kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String] else { return nil }
    return keys.contains("TXM")
}

private func string(_ p: UnsafeMutablePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "?" }

// The mounted developer disk image, or nil if none is. Since iOS and visionOS 26.4 it's a cryptex that
// cryptexd reports; before that a personalized image the image mounter lists.
func mountedDDI(_ tunnel: Tunnel) throws -> String? {
    var installed: UnsafeMutablePointer<InstalledCryptexC>?
    let cryptexError = cryptexd_installed_ddi(tunnel.adapter, tunnel.handshake, &installed)
    if cryptexError == nil {
        defer { cryptexd_free_installed_cryptex(installed) }
        if let c = installed { return "cryptex \(string(c.pointee.identifier)) \(string(c.pointee.version))" }
    }
    var cryptexFailure: Error?
    do { try check("cryptexd", cryptexError) } catch { cryptexFailure = error }
    // Then the image mounter, for an image mounted the pre-26.4 way. When cryptexd answered, its "none"
    // stands even if this check can't be made; when it didn't, both errors are the answer.
    do {
        var mounter: OpaquePointer?
        try check("image mounter", image_mounter_connect_rsd(tunnel.adapter, tunnel.handshake, &mounter))
        defer { image_mounter_free(mounter) }
        var devices: UnsafeMutablePointer<plist_t?>?
        var count = 0
        try check("image mounter devices", image_mounter_copy_devices(mounter, &devices, &count))
        if let devices {
            for i in 0..<count { plist_free(devices[i]) }
            idevice_data_free(UnsafeMutableRawPointer(devices).assumingMemoryBound(to: UInt8.self),
                UInt(count * MemoryLayout<plist_t?>.stride))
        }
        if count > 0 { return "personalized image (\(count) mounted)" }
    } catch {
        if let cryptexFailure { throw HelperError("\(cryptexFailure); \(error)") }
    }
    if let cryptexFailure { throw cryptexFailure }
    return nil
}

// Personalizes the cryptex with Apple's signing server (idevice asks the device for its identifiers and
// nonce, then gs.apple.com for a ticket) and installs it. The files go to a scratch directory laid out as
// the image's Restore directory, because that's what idevice loads, and are deleted afterwards.
func mountDeveloperDiskImage(_ tunnel: Tunnel, files: [String: Data], log: (String) -> Void) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spddi-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    for (path, data) in files {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw HelperError("DDI file path \(path) isn't inside the Restore directory")
        }
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    var assets: OpaquePointer?
    try check("DDI files", dir.path.withCString { cryptex1_assets_load($0, &assets) })
    defer { cryptex1_assets_free(assets) }
    var installed: UnsafeMutablePointer<InstalledCryptexC>?
    let t = now()
    try check("DDI install", cryptexd_install_ddi(tunnel.adapter, tunnel.handshake, assets, &installed))
    defer { cryptexd_free_installed_cryptex(installed) }
    let what = installed.map { "cryptex \(string($0.pointee.identifier)) \(string($0.pointee.version))" } ?? "cryptex"
    log(String(format: "mounted %@ in %.1f s", what, now() - t))
    return what
}

// The GDB remote protocol to debugserver, through idevice's debug proxy.
final class Debugger {
    private let proxy: OpaquePointer
    private var registers: [String: String] = [:]  // name -> debugserver register number (hex)

    init(_ tunnel: Tunnel, log: (String) -> Void) throws {
        var proxy: OpaquePointer?
        try check("debugserver (is the developer disk image mounted?)",
            debug_proxy_connect_rsd(tunnel.adapter, tunnel.handshake, &proxy))
        self.proxy = proxy!
        // As lldb does: acknowledge anything pending, then turn acks off (one fewer round trip per packet).
        try check("debugserver ack", debug_proxy_send_ack(self.proxy))
        if (try? command("QStartNoAckMode")) == "OK" { debug_proxy_set_ack_mode(self.proxy, 0) }
        guard try command("QThreadSuffixSupported") == "OK" else { throw HelperError("debugserver has no thread suffix") }
        // If this connection drops (the helper fails or is killed), debugserver detaches instead of its
        // default, killing the app.
        let detachOnError = try command("QSetDetachOnError:1")
        log("debugserver ready (detach on error: \(detachOnError))")
    }

    // Register numbers from debugserver itself rather than assumed, stopping once ours are known. Only
    // once attached: with no process, debugserver answers qRegisterInfo with an error.
    func loadRegisters() throws {
        let needed = ["x0", "x1", "x2", "x16", "pc"]
        for n in 0..<128 where !needed.allSatisfy({ registers[$0] != nil }) {
            let info = try command("qRegisterInfo\(String(n, radix: 16))")
            if !info.contains("name:") { break }
            for field in info.split(separator: ";") where field.hasPrefix("name:") {
                registers[String(field.dropFirst(5))] = String(n, radix: 16)
            }
        }
        for name in needed where registers[name] == nil {
            throw HelperError("debugserver didn't list register \(name)")
        }
    }

    deinit { debug_proxy_free(proxy) }

    func command(_ packet: String) throws -> String {
        guard let cmd = packet.withCString({ debugserver_command_new($0, nil, 0) }) else {
            throw HelperError("couldn't make the packet \(packet.prefix(16))")
        }
        defer { debugserver_command_free(cmd) }
        var response: UnsafeMutablePointer<CChar>?
        try check("debugserver \(packet.prefix(16))", debug_proxy_send_command(proxy, cmd, &response))
        defer { if let response { idevice_string_free(response) } }
        return Debugger.expand(response.map { String(cString: $0) } ?? "")
    }

    private func read() throws -> String {
        var response: UnsafeMutablePointer<CChar>?
        try check("debugserver reply", debug_proxy_read_response(proxy, &response))
        defer { if let response { idevice_string_free(response) } }
        return Debugger.expand(response.map { String(cString: $0) } ?? "")
    }

    // Many packets in one write, then all their replies: the round trip is paid once per batch.
    func batch(_ packets: [String]) throws -> [String] {
        var bytes = Data()
        for p in packets {
            let sum = p.utf8.reduce(UInt8(0), &+)
            bytes.append(contentsOf: Array("$\(p)#\(String(format: "%02x", sum))".utf8))
        }
        try bytes.withUnsafeBytes {
            try check("debugserver send", debug_proxy_send_raw(proxy, $0.bindMemory(to: UInt8.self).baseAddress, UInt($0.count)))
        }
        return try packets.map { _ in try read() }
    }

    // Resumes and waits for the next stop, skipping the inferior's console output ("O" + hex).
    func resume(_ packet: String) throws -> String {
        var reply = try command(packet)
        while reply.hasPrefix("O") && reply != "OK" { reply = try read() }
        return reply
    }

    // The protocol's run-length encoding: "c*n" is c repeated n - 29 more times.
    static func expand(_ s: String) -> String {
        guard s.contains("*") else { return s }
        var out = ""
        var chars = Array(s)[...]
        while let c = chars.popFirst() {
            if c == "*", let last = out.last, let n = chars.popFirst()?.asciiValue {
                out += String(repeating: last, count: max(0, Int(n) - 29))
            } else {
                out.append(c)
            }
        }
        return out
    }

    func register(_ name: String, thread: String) throws -> UInt64 {
        let reply = try command("p\(registers[name]!);thread:\(thread);")
        guard let value = Debugger.littleEndian(reply) else { throw HelperError("register \(name): \(reply)") }
        return value
    }

    func setRegister(_ name: String, _ value: UInt64, thread: String) throws {
        let hex = (0..<8).map { String(format: "%02x", (value >> (8 * UInt64($0))) & 0xff) }.joined()
        let reply = try command("P\(registers[name]!)=\(hex);thread:\(thread);")
        guard reply == "OK" else { throw HelperError("set \(name): \(reply)") }
    }

    func memory(_ address: UInt64, _ count: Int) throws -> [UInt8] {
        let reply = try command("m\(String(address, radix: 16)),\(String(count, radix: 16))")
        guard let bytes = Debugger.bytes(reply), bytes.count == count else {
            throw HelperError("read \(count) bytes at 0x\(String(address, radix: 16)): \(reply.prefix(16))")
        }
        return bytes
    }

    static func bytes(_ hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(b)
        }
        return out
    }

    static func littleEndian(_ hex: String) -> UInt64? {
        guard let b = bytes(hex), b.count == 8 else { return nil }
        return b.reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }
}

// `brk #0xf00d`: what the app executes to ask for a prepare or a detach.
private let brkF00d: [UInt8] = [0xa0, 0x01, 0x3e, 0xd4]
private let pageSize: UInt64 = 0x4000

// The stop reply's signal and its key:value fields ("T05thread:1a2b;...").
private func parseStop(_ reply: String) -> (signal: Int, fields: [String: String]) {
    guard reply.count >= 3, reply.first == "T" || reply.first == "S",
          let signal = Int(reply.dropFirst().prefix(2), radix: 16) else { return (-1, [:]) }
    var fields: [String: String] = [:]
    for pair in reply.dropFirst(3).split(separator: ";") {
        let kv = pair.split(separator: ":", maxSplits: 1)
        if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
    }
    return (signal, fields)
}

// Attaches to `pid` and services its requests until it asks to detach or exits.
//
// A prepare (x16 = 1) writes one byte to every 16 KB page of x0..x0+x1: a debugger's write is what makes
// a page executable after the app writes code to it through an alias (docs/architecture.md, "Executable
// memory under TXM"). The byte written is the page's own first byte when the app passes them (x2: one per
// page), so the contents don't change; otherwise 0x69, as StikDebug writes, and the app restores the
// contents itself. Addresses are full 64-bit (StikJIT formats 9 hex digits and silently skips regions at
// or above 2^36). Packets go in batches of 128, written together and their replies read after.
func serve(pid: Int32, tunnel: Tunnel, log: (String) -> Void) throws -> String {
    let t0 = now()
    let debugger = try Debugger(tunnel, log: log)
    var stop = try debugger.command("vAttach;\(String(pid, radix: 16))")
    guard stop.first == "T" || stop.first == "S" else { throw HelperError("attach to \(pid) refused: \(stop)") }
    try debugger.loadRegisters()
    log(String(format: "attached to %d in %.3f s", pid, now() - t0))
    var prepares = 0, pages = 0, failed = 0
    var prepareTime = 0.0
    while true {
        if stop.first == "W" || stop.first == "X" {
            return "process exited (\(stop)) after \(prepares) prepares, \(pages) pages"
        }
        let (signal, fields) = parseStop(stop)
        guard signal >= 0, let thread = fields["thread"] else { throw HelperError("unexpected stop reply: \(stop.prefix(40))") }
        var resume = "c"
        let pc = signal == 5 ? try debugger.register("pc", thread: thread) : 0
        if signal == 5, try debugger.memory(pc, 4) == brkF00d {
            let cmd = try debugger.register("x16", thread: thread)
            try debugger.setRegister("pc", pc + 4, thread: thread)
            if cmd == 0 {
                let reply = try debugger.command("D")
                return String(format: "detached (%@) %.2f s after attaching: %d prepares, %d pages, %d failed writes, %.3f s writing",
                    reply, now() - t0, prepares, pages, failed, prepareTime)
            } else if cmd == 1 {
                let address = try debugger.register("x0", thread: thread)
                let length = try debugger.register("x1", thread: thread)
                let firsts = try debugger.register("x2", thread: thread)
                let t = now()
                let (n, bad) = try prepare(debugger, address: address, length: length, firsts: firsts, log: log)
                prepareTime += now() - t
                prepares += 1
                pages += n
                failed += bad
                // The app gets the address back in x0, or 0 if the debugger allocates (not supported here).
                try debugger.setRegister("x0", address, thread: thread)
            } else {
                log("unknown request x16 = \(cmd); resuming with x0 = 0")
                try debugger.setRegister("x0", 0, thread: thread)
            }
        } else if signal != 0x11 && signal != 0 {
            // Not ours, and not the attach's own SIGSTOP: deliver it, as it would be with no debugger.
            resume = String(format: "C%02x", signal)
        }
        stop = try debugger.resume(resume)
    }
}

private func prepare(_ debugger: Debugger, address: UInt64, length: UInt64, firsts: UInt64,
                     log: (String) -> Void) throws -> (pages: Int, failed: Int) {
    guard address != 0 else {
        log("prepare with x0 = 0 (debugger allocates) isn't supported")
        return (0, 0)
    }
    let start = address & ~(pageSize - 1)
    let end = (address + length + pageSize - 1) & ~(pageSize - 1)
    let addresses = Array(stride(from: start, to: end, by: Int(pageSize)))
    // x2's array starts at x0's page, one byte per page of x1 rounded down (main.c and the shim fill it
    // that way), so a trailing partial page falls back to 0x69.
    var values = [UInt8](repeating: 0x69, count: addresses.count)
    if firsts != 0 && start == address {
        let known = min(addresses.count, Int(length / pageSize))
        var read: [UInt8] = []
        while read.count < known { read += try debugger.memory(firsts + UInt64(read.count), min(0x800, known - read.count)) }
        values.replaceSubrange(0..<known, with: read)
    }
    var failed = 0
    var firstFailure = ""
    for chunk in stride(from: 0, to: addresses.count, by: 128) {
        let range = chunk..<min(chunk + 128, addresses.count)
        let replies = try debugger.batch(range.map {
            "M\(String(addresses[$0], radix: 16)),1:\(String(format: "%02x", values[$0]))"
        })
        for r in replies where r != "OK" {
            failed += 1
            if firstFailure.isEmpty { firstFailure = r }
        }
    }
    // Read back the first and last page's byte: a write the device dropped would show here.
    let first = try debugger.memory(addresses.first!, 1)[0]
    let last = try debugger.memory(addresses.last!, 1)[0]
    let ok = first == values.first! && last == values.last!
    log(String(format: "prepared 0x%llx+0x%llx: %d pages, %d failed%@, %@ values, read back %@", address, length,
        addresses.count, failed, firstFailure.isEmpty ? "" : " (first: \(firstFailure))",
        firsts != 0 ? "own first-byte" : "0x69", ok ? "ok" : "WRONG"))
    return (addresses.count, failed)
}
#endif
