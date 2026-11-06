import Foundation
import IOKit

/// The USB link an iPad or iPhone has to this Mac, from IOKit, for the main window's cable line. A copy of
/// game files runs at the link's speed: the rc9 run copied Classic Era (33.26 GB) to the iPhone 16 Pro in
/// 17 minutes, ~32 MB/s, over the USB 2 cable that comes in the box (IOKit's Device Speed 2), though the
/// iPhone does 10 Gbit/s with a USB 3 cable. Nothing here is logged but the speed.
struct USBLink: Equatable {
    /// IOUSBHostDevice's "Device Speed": 0 low, 1 full, 2 high (USB 2, 480 Mbit/s), 3 SuperSpeed (USB 3,
    /// 5 Gbit/s), 4 and up SuperSpeed+ (10 Gbit/s and more; a T7 SSD on the main Mac reads 4).
    let speed: Int

    /// USB 2 or slower: what a USB 3 cable would beat several times over.
    var isUSB2: Bool { speed <= 2 }

    /// For the log: "USB 2 (480 Mbit/s)".
    var text: String {
        switch speed {
        case ...0: "USB 1 (1.5 Mbit/s)"
        case 1: "USB 1 (12 Mbit/s)"
        case 2: "USB 2 (480 Mbit/s)"
        case 3: "USB 3 (5 Gbit/s)"
        default: "USB 3 (10 Gbit/s or more)"
        }
    }

    /// The device's link now, nil when it isn't on USB (the headset, or an iPad or iPhone over Wi-Fi).
    /// A plain IOKit registry read, a millisecond or so, so the 15 s device check can afford it, and a
    /// running copy every few seconds.
    static func now(udid: String) -> USBLink? {
        link(udid: udid, in: usbDevices())
    }

    /// The link of the device whose USB serial number is `udid`: an iPad's or iPhone's is its UDID without
    /// the dash (checked on the iPhone 16 Pro; a 40-digit UDID has none to drop).
    static func link(udid: String, in devices: [(serial: String, speed: Int)]) -> USBLink? {
        let serial = udid.replacingOccurrences(of: "-", with: "").uppercased()
        guard !serial.isEmpty, let d = devices.first(where: { $0.serial.uppercased() == serial }) else { return nil }
        return USBLink(speed: d.speed)
    }

    /// Whether the device can do USB 3 with a USB 3 cable, by model (productType), so the line isn't shown
    /// to a device that can't do better. Every iPad the client supports can (USB 3 up to 10 Gbit/s on
    /// the Airs and the A17 Pro mini, Thunderbolt on the Pros), and so can the Pro iPhones from the 15 Pro on, numbered N,1 and N,2
    /// (iPhone16,1 and 16,2, 17,1 and 17,2, 18,1 and 18,2). The other iPhones the client supports (the 16,
    /// 16 Plus, 16e, 17, and Air) are USB 2 only. The headset has no USB to copy over. False for an
    /// unknown model: better no line than a wrong one.
    static func supportsUSB3(kind: Device.Kind, model: String?) -> Bool {
        guard let model else { return false }
        switch kind {
        case .headset:
            return false
        case .iPad:
            return model.hasPrefix("iPad") && Device.isSupportedIPad(model: model)
        case .iPhone:
            guard let m = model.firstMatch(of: /^iPhone(\d+),(\d+)$/), let major = Int(m.1), let minor = Int(m.2) else { return false }
            return major >= 16 && minor <= 2
        }
    }

    /// Whether to say "This cable is USB 2": the device copies game files from this Mac (`copying`), is on
    /// USB at USB 2 speed or less, and could do USB 3. A copy measured (`copyRate`, bytes/s) faster than
    /// USB 2 can carry has the last word over a link reading: the line must never sit over a 277 MB/s
    /// copy, as it did in a dev build on 2026-10-28.
    static func slowCable(_ link: USBLink?, kind: Device.Kind, model: String?, copying: Bool, copyRate: Double? = nil) -> Bool {
        guard copying, let link else { return false }
        if let copyRate, copyRate > usb2Rate { return false }
        return link.isUSB2 && supportsUSB3(kind: kind, model: model)
    }

    /// About the most a copy gets through USB 2 (480 Mbit/s on the wire, ~35 MB/s measured in the rc9 run).
    static let usb2Rate = 40e6

    /// What the main window and a copy's progress say about it.
    static let slowCableLine = "This cable is USB 2; a USB 3 cable copies game files several times faster."

    /// Every USB device's serial number and speed, from IOKit's IOUSBHostDevice entries.
    private static func usbDevices() -> [(serial: String, speed: Int)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var devices: [(serial: String, speed: Int)] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let serial = property("USB Serial Number") as? String,
                  let speed = (property("Device Speed") as? NSNumber)?.intValue else { continue }
            devices.append((serial, speed))
        }
        return devices
    }
}
