// Experiment p1: can the app make its own RemotePairing record on the device, with no Mac? A fresh record
// (rp_pairing_file_generate) fails pair-verify on the tunnel to the device's own RemotePairing service
// through the loopback VPN (10.7.0.1:49152), so idevice runs pair-setup on the same connection and asks
// for the PIN the device shows. jittest has no UI, so the PIN comes from Documents/spjit-pin (put there
// with devicectl copy to, from what the device shows), polled for up to 3 minutes. On success the record
// is written to Documents/pairingFile-p1.plist, never read back here or logged (its size only), and the
// tunnel it opened is the proof that the device accepts it.
//
// In the host, not the helper: pairing involves no debugger, and devicectl can't reach the helper's
// container to hand it the PIN.
#if SP_IDEVICE
import Foundation
import idevice

private func pinFile() -> URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/spjit-pin")
}

nonisolated(unsafe) private var pinLog: HostLog?
nonisolated(unsafe) private var pinAsked = false
nonisolated(unsafe) private var pinBuffer: UnsafeMutablePointer<CChar>?

// idevice calls this on its own thread and blocks on it, so polling here is fine.
private let askPin: @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? = { _ in
    pinAsked = true
    pinLog?.say("the device wants a PIN: waiting up to 3 minutes for Documents/spjit-pin")
    let t = Date()
    while Date().timeIntervalSince(t) < 180 {
        if let pin = try? String(contentsOf: pinFile(), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !pin.isEmpty {
            try? FileManager.default.removeItem(at: pinFile())
            pinLog?.say("got a \(pin.count)-character PIN after \(Int(Date().timeIntervalSince(t))) s")
            free(pinBuffer)
            pinBuffer = strdup(pin)
            return UnsafePointer(pinBuffer)
        }
        usleep(250_000)
    }
    pinLog?.say("no PIN after 3 minutes")
    return nil
}

@_cdecl("sp_pair")
func sp_pair(_ out: SPLog) -> Int32 {
    let log = HostLog(out)
    pinLog = log
    try? FileManager.default.removeItem(at: pinFile())
    var record: OpaquePointer?
    do {
        try check("generate", rp_pairing_file_generate("Slashplayed", &record))
    } catch {
        log.say("FAIL: \(error)")
        return 1
    }
    defer { rp_pairing_file_free(record) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(49152).bigEndian
    inet_pton(AF_INET, "10.7.0.1", &address.sin_addr)
    var adapter: OpaquePointer?
    var handshake: OpaquePointer?
    let t = now()
    log.say("pairing through 10.7.0.1:49152 with a fresh record")
    let error = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.size), "Slashplayed", record,
                askPin, nil, &adapter, &handshake)
        }
    }
    do {
        try check("pair", error)
    } catch {
        log.say(String(format: "FAIL after %.1f s (%@): %@", now() - t,
            pinAsked ? "a PIN was asked for" : "no PIN was asked for", "\(error)"))
        return 1
    }
    defer {
        rsd_handshake_free(handshake)
        adapter_free(adapter)
    }
    log.say(String(format: "tunnel up with the new record after %.1f s (%@)", now() - t,
        pinAsked ? "after pair-setup" : "no pair-setup: the device already knew it?"))
    let path = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/pairingFile-p1.plist").path
    do {
        try check("write", rp_pairing_file_write(record, path))
    } catch {
        log.say("FAIL: \(error)")
        return 1
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? -1
    log.say("wrote Documents/pairingFile-p1.plist (\(size) bytes)")
    return 0
}

// Experiment p2: pairing the way Xcode pairs a Vision Pro over Wi-Fi. With Settings > General > Remote
// Devices open, visionOS advertises _remotepairing-manual-pairing._tcp and shows a code; pair-setup there
// with that code (rppairing_pair_network) makes the record. Then a tunnel through 10.7.0.1:49152 with it
// proves the device accepts it. Same PIN file and output as p1 (Documents/pairingFile-p2.plist).
func pairManual(_ log: HostLog) async -> Int32 {
    pinLog = log
    try? FileManager.default.removeItem(at: pinFile())
    return await {
        var endpoints: [String] = []
        for _ in 0..<10 where endpoints.isEmpty {
            endpoints = await bonjourEndpoints(log, type: "_remotepairing-manual-pairing._tcp")
        }
        if endpoints.isEmpty {
            log.say("FAIL: no _remotepairing-manual-pairing._tcp service (is Settings > General > Remote Devices open?)")
            return 1
        }
        var record: OpaquePointer?
        do {
            try check("generate", rp_pairing_file_generate("Slashplayed", &record))
        } catch {
            log.say("FAIL: \(error)")
            return 1
        }
        defer { rp_pairing_file_free(record) }
        var paired = false
        for endpoint in endpoints where !paired {
            guard case (var address, let length)? = socketAddress(endpoint) else { continue }
            let t = now()
            log.say("pair-setup through \(endpoint)")
            let error = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    rppairing_pair_network($0, length, "Slashplayed", record, askPin, nil, nil)
                }
            }
            do {
                try check(endpoint, error)
                log.say(String(format: "paired through %@ after %.1f s", endpoint, now() - t))
                paired = true
            } catch {
                log.say(String(format: "failed after %.1f s (%@): %@", now() - t,
                    pinAsked ? "a PIN was asked for" : "no PIN was asked for", "\(error)"))
            }
        }
        guard paired else { return 1 }
        let path = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/pairingFile-p2.plist").path
        do {
            try check("write", rp_pairing_file_write(record, path))
        } catch {
            log.say("FAIL: \(error)")
            return 1
        }
        guard let data = FileManager.default.contents(atPath: path) else { return 1 }
        log.say("wrote Documents/pairingFile-p2.plist (\(data.count) bytes); trying a tunnel with it")
        do {
            _ = try Tunnel.open(pairing: data, endpoints: ["10.7.0.1:49152"], log: { log.say($0) })
            return 0
        } catch {
            log.say("FAIL: \(error)")
            return 1
        }
    }()
}

#else
@_cdecl("sp_pair")
func sp_pair(_ out: SPLog) -> Int32 {
    HostLog(out).say("FAIL: built without idevice (scripts/build-idevice.sh)")
    return 1
}

func pairManual(_ log: HostLog) async -> Int32 {
    log.say("FAIL: built without idevice (scripts/build-idevice.sh)")
    return 1
}
#endif
