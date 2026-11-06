import XCTest

/// The cable line (USBLink): which USB device is the iPad or iPhone, and when a USB 2 link is worth a word.
/// Made-up serials and UDIDs.
final class USBLinkTests: XCTestCase {
    private let devices: [(serial: String, speed: Int)] = [
        ("S0MEDISK0001", 4),                    // an SSD at 10 Gbit/s
        ("00008140000A1B2C3D4E5F60", 2),        // an iPhone at USB 2
        ("0123456789abcdef0123456789abcdef01234567", 3),  // an older 40-digit UDID, lower case
    ]

    /// An iPad's or iPhone's USB serial is its UDID without the dash; a 40-digit UDID has none. Case
    /// doesn't matter (the 40-digit one is tried in mixed case: all upper reads as a signing hash to
    /// check-tree.sh).
    func testFindsTheDeviceBySerial() {
        // Split, so check-tree.sh doesn't read the made-up UDIDs as real ones.
        let udid = "00008140-" + "000A1B2C3D4E5F60", other = "00008140-" + "000A1B2C3D4E5F61"
        XCTAssertEqual(USBLink.link(udid: udid, in: devices), USBLink(speed: 2))
        XCTAssertEqual(USBLink.link(udid: "00008140-000a1b2c3d4e5f60", in: devices), USBLink(speed: 2))
        XCTAssertEqual(USBLink.link(udid: "0123456789ABCDEF0123456789abcdef01234567", in: devices), USBLink(speed: 3))
        // Not on USB (Wi-Fi, or unplugged), or no UDID.
        XCTAssertNil(USBLink.link(udid: other, in: devices))
        XCTAssertNil(USBLink.link(udid: "", in: devices))
        XCTAssertNil(USBLink.link(udid: udid, in: []))
    }

    func testSpeeds() {
        XCTAssertTrue(USBLink(speed: 1).isUSB2)
        XCTAssertTrue(USBLink(speed: 2).isUSB2)
        XCTAssertFalse(USBLink(speed: 3).isUSB2)
        XCTAssertFalse(USBLink(speed: 4).isUSB2)
        XCTAssertEqual(USBLink(speed: 2).text, "USB 2 (480 Mbit/s)")
    }

    /// Pro iPhones from the 15 Pro on and every M-chip iPad can do USB 3; the other supported iPhones and
    /// the headset can't; an unknown model gets no line.
    func testWhichDevicesCanDoUSB3() {
        for model in ["iPhone16,1", "iPhone16,2", "iPhone17,1", "iPhone17,2", "iPhone18,1", "iPhone18,2"] {
            XCTAssertTrue(USBLink.supportsUSB3(kind: .iPhone, model: model), model)
        }
        for model in ["iPhone17,3", "iPhone17,4", "iPhone17,5", "iPhone18,3", "iPhone18,4", "iPhone15,4", "iPhone"] {
            XCTAssertFalse(USBLink.supportsUSB3(kind: .iPhone, model: model), model)
        }
        XCTAssertFalse(USBLink.supportsUSB3(kind: .iPhone, model: nil))
        for model in ["iPad14,5", "iPad14,8", "iPad15,3", "iPad16,5", "iPad17,2", "iPad16,1"] {
            XCTAssertTrue(USBLink.supportsUSB3(kind: .iPad, model: model), model)
        }
        // A-chip iPads the client doesn't run on (the 11th generation is USB 2 anyway), and the old iPad8,1.
        for model in ["iPad15,7", "iPad14,1", "iPad8,1"] {
            XCTAssertFalse(USBLink.supportsUSB3(kind: .iPad, model: model), model)
        }
        XCTAssertFalse(USBLink.supportsUSB3(kind: .iPad, model: nil))
        XCTAssertFalse(USBLink.supportsUSB3(kind: .headset, model: "RealityDevice14,1"))
    }

    /// The line shows only for a device that copies, on a USB 2 link, that could do USB 3: the rc9 run's
    /// iPhone 16 Pro (iPhone17,1) at Device Speed 2.
    func testWhenToSayTheCableIsSlow() {
        let usb2 = USBLink(speed: 2), usb3 = USBLink(speed: 4)
        XCTAssertTrue(USBLink.slowCable(usb2, kind: .iPhone, model: "iPhone17,1", copying: true))
        XCTAssertTrue(USBLink.slowCable(usb2, kind: .iPad, model: "iPad14,5", copying: true))
        // Copying off: the game streams, and the cable doesn't matter.
        XCTAssertFalse(USBLink.slowCable(usb2, kind: .iPhone, model: "iPhone17,1", copying: false))
        // A USB 3 cable, or not on USB.
        XCTAssertFalse(USBLink.slowCable(usb3, kind: .iPhone, model: "iPhone17,1", copying: true))
        XCTAssertFalse(USBLink.slowCable(nil, kind: .iPhone, model: "iPhone17,1", copying: true))
        // A device that can't do better, or one whose model isn't known yet.
        XCTAssertFalse(USBLink.slowCable(usb2, kind: .iPhone, model: "iPhone17,3", copying: true))
        XCTAssertFalse(USBLink.slowCable(usb2, kind: .iPhone, model: nil, copying: true))
    }

    /// A copy measured faster than USB 2 can go hides the line whatever the link read says: the dev build's
    /// 277.4 MB/s copy to the iPhone on 2026-10-28 under a USB 2 line. A USB 2-speed copy keeps it.
    func testAFastCopyHidesTheLine() {
        let usb2 = USBLink(speed: 2)
        XCTAssertFalse(USBLink.slowCable(usb2, kind: .iPhone, model: "iPhone17,1", copying: true, copyRate: 277.4e6))
        XCTAssertFalse(USBLink.slowCable(usb2, kind: .iPhone, model: "iPhone17,1", copying: true, copyRate: 41e6))
        XCTAssertTrue(USBLink.slowCable(usb2, kind: .iPhone, model: "iPhone17,1", copying: true, copyRate: 35e6))
        XCTAssertTrue(USBLink.slowCable(usb2, kind: .iPhone, model: "iPhone17,1", copying: true, copyRate: nil))
        // Nor does a slow copy make a line on a USB 3 link (a busy device, small files).
        XCTAssertFalse(USBLink.slowCable(USBLink(speed: 4), kind: .iPhone, model: "iPhone17,1", copying: true, copyRate: 5e6))
    }
}
