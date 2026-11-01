import Foundation
import idevice

/// The device's RemotePairing record: what the client's JIT helper on an iPad or iPhone needs to open the
/// RemotePairing tunnel to the device's own debugserver through the loopback VPN, with no Mac at launch
/// (research/jittest). iOS won't make one on the device itself (its network RemotePairing service resets
/// a host it doesn't trust, before any pair-setup), so the companion makes it once, over USB, through
/// lockdown's remotepairingdeviced service: usbmuxd hands over this Mac's lockdown pair record for the
/// device (held in memory by idevice, never read here or logged), and pairing over USB needs no prompt.
/// The headset pairs itself (Settings > General > Remote Devices, apps/client/sppair.m), so it only gets
/// its record cleared here (clear, for Pair Again).
///
/// The record is a credential that can do anything this Mac's pairing can, until the device forgets it
/// (Settings > Developer > Clear Trusted Computers, which unpairs the Mac too). So it's never read,
/// printed or logged: it goes from idevice to a file only this user can read, from there to the app's
/// data container, and the Mac's copy is deleted. Only its size is logged.
///
/// Lockdown, through the same usbmuxd, also says how much space the device has free (freeSpace).
///
/// idevice (scripts/build-idevice.sh macos) is linked statically; Generated/idevice.xcconfig names it.
enum Pairing {
    /// Where the client finds it, in its data container.
    static let devicePath = "Library/sppairing.plist"
    /// The name the device lists the pairing under.
    static let hostName = "Slashplayed"

    /// Makes a record for `udid` (on USB) and copies it into the app's data container on `device`.
    /// Returns its size.
    static func send(to device: Device) async throws -> Int {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sppairing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "sppairing.plist")
        let udid = device.udid
        let record = try await Task.detached { try make(udid: udid) }.value
        defer { overwrite(file) }
        guard FileManager.default.createFile(atPath: file.path, contents: record, attributes: [.posixPermissions: 0o600]) else {
            throw Failure("Couldn't write the pairing record to \(dir.path).")
        }
        try await device.copy(file, to: devicePath)
        return record.count
    }

    /// Empties the app's record on `device`, which its launcher takes as none (apps/client/spjit.m): the
    /// headset then pairs again on its next launch. devicectl can't delete a file, so it's overwritten.
    static func clear(on device: Device) async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sppairing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "sppairing.plist")
        guard FileManager.default.createFile(atPath: file.path, contents: Data()) else {
            throw Failure("Couldn't write an empty file to \(dir.path).")
        }
        try await device.copy(file, to: devicePath)
    }

    /// Zeroes a file before it's deleted, as rm -P does: the record shouldn't outlive the copy on disk.
    private static func overwrite(_ file: URL) {
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: Data(count: Int(size)))
        try? handle.synchronize()
    }

    /// Pairs with `udid` through usbmuxd and lockdown and returns the new record's bytes. Blocks (idevice
    /// runs its own runtime underneath), so it runs off the main actor.
    static func make(udid: String) throws -> Data {
        let provider = try provider(udid: udid,
                                    notOnUSB: "Connect the device to this Mac with its USB cable, unlock it, and try again: the companion makes its pairing record over USB.")
        defer { idevice_provider_free(provider) }
        var client: OpaquePointer?
        try check("remotepairingdeviced", remote_pairing_lockdown_connect(provider, hostName, &client))
        defer { remote_pairing_lockdown_free(client) }
        var record: OpaquePointer?
        try check("new pairing record", rp_pairing_file_generate(hostName, &record))
        defer { rp_pairing_file_free(record) }
        // Pair-verify, then pair-setup when the device doesn't know the record (a fresh one never is).
        try check("pairing", remote_pairing_lockdown_connect_pairing(client, record, nil))
        var bytes: UnsafeMutablePointer<UInt8>?
        var length: UInt = 0
        try check("pairing record", rp_pairing_file_to_bytes(record, &bytes, &length))
        defer { idevice_data_free(bytes, length) }
        guard let bytes, length > 0 else { throw Failure("idevice returned an empty pairing record.") }
        return Data(bytes: bytes, count: Int(length))
    }

    /// The device's free space, as lockdown has it now (com.apple.disk_usage's AmountDataAvailable), for an
    /// iPad or iPhone usbmuxd can reach: unlike Device.freeSpace's file, it's there before Slashplayed first
    /// starts. Over USB or the network: a read asks the device nothing (the iPhone over Wi-Fi, 2026-10-25).
    /// The session uses this Mac's lockdown pair record, which usbmuxd hands to idevice and which stays in
    /// its memory, as for make. Nil if usbmuxd doesn't list the device or lockdown doesn't say. Blocks, as make.
    static func freeSpace(udid: String) -> Int64? {
        guard let provider = try? provider(udid: udid, notOnUSB: nil) else { return nil }
        defer { idevice_provider_free(provider) }
        var lockdown: OpaquePointer?
        guard (try? check("lockdownd", lockdownd_connect(provider, &lockdown))) != nil else { return nil }
        defer { lockdownd_client_free(lockdown) }
        var record: OpaquePointer?
        guard (try? check("pair record", idevice_provider_get_pairing_file(provider, &record))) != nil else { return nil }
        defer { idevice_pairing_file_free(record) }
        guard (try? check("lockdown session", lockdownd_start_session(lockdown, record))) != nil else { return nil }
        var value: plist_t?
        guard (try? check("disk usage", lockdownd_get_value(lockdown, "AmountDataAvailable", "com.apple.disk_usage", &value))) != nil,
              let value else { return nil }
        defer { plist_free(value) }
        guard plist_get_node_type(value) == PLIST_INT else { return nil }
        var bytes: UInt64 = 0
        plist_get_uint_val(value, &bytes)
        return bytes > 0 ? Int64(bytes) : nil
    }

    /// An idevice provider for the device through usbmuxd, which the caller frees. With `notOnUSB`, only on
    /// USB: pairing over Wi-Fi may ask the device to trust it, so make asks for the cable (that message)
    /// rather than guess.
    private static func provider(udid: String, notOnUSB: String?) throws -> OpaquePointer? {
        // The device as usbmuxd sees it: its muxer ID, and whether it's on USB.
        var muxer: OpaquePointer?
        try check("usbmuxd", idevice_usbmuxd_new_default_connection(0, &muxer))
        defer { idevice_usbmuxd_connection_free(muxer) }
        var list: UnsafeMutablePointer<OpaquePointer?>?
        var count: Int32 = 0
        try check("usbmuxd devices", idevice_usbmuxd_get_devices(muxer, &list, &count))
        defer { idevice_usbmuxd_device_list_free(list, count) }
        var found: (id: UInt32, usb: Bool)?
        for i in 0..<Int(count) {
            guard let d = list?[i], let u = idevice_usbmuxd_device_get_udid(d) else { continue }
            defer { idevice_string_free(u) }
            guard String(cString: u) == udid else { continue }
            let usb = idevice_usbmuxd_device_get_connection_type(d) == 1  // UsbmuxdConnectionType::Usb
            if found == nil || usb { found = (idevice_usbmuxd_device_get_device_id(d), usb) }
        }
        guard let found else { throw Failure(notOnUSB ?? "usbmuxd doesn't list the device.") }
        if let notOnUSB, !found.usb { throw Failure(notOnUSB) }
        var addr: OpaquePointer?
        try check("usbmuxd address", idevice_usbmuxd_default_addr_new(&addr))
        var provider: OpaquePointer?
        // The provider takes the address, whether or not it succeeds.
        try check("usbmuxd provider", usbmuxd_provider_new(addr, 0, udid, found.id, hostName, &provider))
        return provider
    }

    /// Turns an idevice error into a thrown one, freeing it.
    private static func check(_ what: String, _ error: UnsafeMutablePointer<IdeviceFfiError>?) throws {
        guard let error else { return }
        let message = error.pointee.message.map { String(cString: $0) } ?? "no message"
        let code = error.pointee.code
        idevice_error_free(error)
        throw Failure("Couldn't pair (\(what)): \(message) (\(code)).")
    }
}

extension Device {
    /// The space free on the device, by the measure its Settings app shows (FreeSpace.now): an iPad or iPhone
    /// usbmuxd lists says now, through lockdown (Pairing.freeSpace), so it's known before Slashplayed first
    /// starts there (the rc6 run's iPad showed none), and the launcher's last figures add the space iOS can
    /// clear, which lockdown leaves out. Otherwise (the headset, or a device usbmuxd doesn't list) it's the
    /// launcher's figure from when the client last started. Nil if neither is known.
    func freeSpaceNow() async -> FreeSpace? { await freeSpaceAndApp().free }

    /// freeSpaceNow, and whether its read of the app's data container found Slashplayed missing there
    /// (Device.AppMissing; lockdown's figure is still given), for the main window's idle heading.
    func freeSpaceAndApp() async -> (free: FreeSpace?, appMissing: Bool) {
        var lockdown: Int64?
        if kind != .headset {
            let udid = udid
            lockdown = await Task.detached(operation: { Pairing.freeSpace(udid: udid) }).value
        }
        do {
            return (FreeSpace.now(lockdown: lockdown, launcher: try await launcherFreeSpace()), false)
        } catch {
            return (FreeSpace.now(lockdown: lockdown, launcher: nil), true)
        }
    }
}
