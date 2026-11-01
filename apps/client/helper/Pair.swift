// The headset's pairing (op "pair"), the way Xcode pairs a Vision Pro over Wi-Fi (research/jittest's p2).
// With Settings > General > Remote Devices open, visionOS advertises _remotepairing-manual-pairing._tcp.
// The app finds it over Bonjour and passes its endpoints (apps/client/sppair.m: the browse is the app's, so
// the local network prompt is too). Pair-setup there gets the headset to show a six-digit code, which only
// the person can read, while this request is still running: a request has one reply and no channel in, so
// the code comes over a loopback connection to the app's listener ("pinPort"), which answers only once it
// has been sent the request's "pinToken". The new record is proved with a tunnel through 10.7.0.1:49152,
// then returned as bytes in the reply ("pairing"): never logged or written to disk here.
//
// In the helper, not the app, so idevice stays out of the launcher: one copy of it, in the one process
// that already talks to the device's services. iOS refuses pair-setup with itself (jittest's p1), so an
// iPad or iPhone gets its record from the Mac instead (the companion's Pairing.swift).
#if SP_IDEVICE
import Foundation
import idevice

// What idevice's PIN callback asks: one loopback connection to the app per call, which blocks until the
// person has typed the code in (or the app gives up and closes it).
private final class PinSource {
    let port: UInt16
    let token: String
    let log: (String) -> Void
    var asked = false
    private var buffer: UnsafeMutablePointer<CChar>?

    init(port: UInt16, token: String, log: @escaping (String) -> Void) {
        self.port = port
        self.token = token
        self.log = log
    }

    deinit { free(buffer) }

    func pin() -> UnsafePointer<CChar>? {
        asked = true
        log("the headset is showing a code: asking the app for it")
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log("socket: errno \(errno)")
            return nil
        }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            log("connect to the app's code listener: errno \(errno) (\(String(cString: strerror(errno))))")
            return nil
        }
        // The person may take a while; the app closes the connection if they give up first.
        var timeout = timeval(tv_sec: 600, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let hello = Array((token + "\n").utf8)
        guard write(fd, hello, hello.count) == hello.count else {
            log("write to the app's code listener: errno \(errno)")
            return nil
        }
        var line: [UInt8] = []
        var c: UInt8 = 0
        while line.count < 64, read(fd, &c, 1) == 1, c != UInt8(ascii: "\n") { line.append(c) }
        let pin = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard !pin.isEmpty else {
            log("the app sent no code")
            return nil
        }
        log("got a \(pin.count)-digit code from the app")
        free(buffer)
        buffer = strdup(pin)
        return UnsafePointer(buffer)
    }
}

private let askPin: @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? = { context in
    guard let context else { return nil }
    return Unmanaged<PinSource>.fromOpaque(context).takeUnretainedValue().pin()
}

// Pair-setup through the first of `endpoints` that's the manual pairing service, and the new record.
func pair(endpoints: [String], pinPort: UInt16, pinToken: String, log: @escaping (String) -> Void) throws -> Data {
    guard pinPort != 0, !pinToken.isEmpty else { throw HelperError("no code listener in the request") }
    var record: OpaquePointer?
    try check("generate", rp_pairing_file_generate("Slashplayed", &record))
    defer { rp_pairing_file_free(record) }
    let source = PinSource(port: pinPort, token: pinToken, log: log)
    var failures: [String] = []
    var paired = false
    for endpoint in endpoints where !paired {
        guard case (var address, let length)? = socketAddress(endpoint) else {
            failures.append("\(endpoint): not a numeric host:port")
            continue
        }
        source.asked = false
        let t = now()
        log("pair-setup through \(endpoint)")
        let error = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                rppairing_pair_network($0, length, "Slashplayed", record, askPin,
                    Unmanaged.passUnretained(source).toOpaque(), nil)
            }
        }
        do {
            try check(endpoint, error)
            log(String(format: "paired through %@ after %.1f s", endpoint, now() - t))
            paired = true
        } catch {
            failures.append("\(error)")
            // A code was asked for, so this was the service and the code was wrong or never came. Another
            // endpoint (the same service by its other address) would only show the person a new code.
            if source.asked { break }
        }
    }
    guard paired else { throw HelperError("pairing failed: " + failures.joined(separator: "; ")) }
    var bytes: UnsafeMutablePointer<UInt8>?
    var count: UInt = 0
    try check("record", rp_pairing_file_to_bytes(record, &bytes, &count))
    guard let bytes else { throw HelperError("record: no bytes") }
    let data = Data(bytes: bytes, count: Int(count))
    idevice_data_free(bytes, count)
    log("new pairing record: \(data.count) bytes; trying a tunnel with it")
    _ = try Tunnel.open(pairing: data, endpoints: ["10.7.0.1:49152"], log: log)
    return data
}
#endif
