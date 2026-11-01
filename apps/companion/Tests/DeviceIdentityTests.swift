import Security
import XCTest

/// DeviceIdentity: which key source a team uses, the per-device opt-in, the launcher's status line, the
/// push decision, and the export. The export runs on a throwaway identity made here, in a keychain file of
/// its own under $TMPDIR that's never on the search list and is deleted afterwards; the login keychain and
/// the owner's identities are never touched.
final class DeviceIdentityTests: XCTestCase {
    static let scratch = FileManager.default.temporaryDirectory.appending(path: "sp-device-identity-tests-\(getpid())")
    /// One per test: a keychain recreated at the same path is still the deleted one to this process.
    static var keychainPath = scratch.appending(path: "test.keychain-db")
    /// The keychain's own password, random per run.
    static let keychainPassword = UUID().uuidString

    override class func tearDown() {
        _ = try? run("/usr/bin/security", ["delete-keychain", keychainPath.path])
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], in directory: URL = scratch) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = directory
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw Failure("\(tool) \(args.first ?? "") failed: \(text)") }
        return text
    }

    /// A self-signed certificate and its key, imported into a fresh keychain file (unlocked, not on the
    /// search list). `trusted`: every app may use the key without asking (security import -A), as a test
    /// needs for the export to run without macOS's prompt; otherwise only `security` may, so an export from
    /// this test asks. Returns the keychain and the certificate's SHA-1.
    static func makeKeychain(trusted: Bool) throws -> (SecKeychain, String) {
        _ = try? run("/usr/bin/security", ["delete-keychain", keychainPath.path])
        try? FileManager.default.removeItem(at: scratch)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        keychainPath = scratch.appending(path: "test-\(UUID().uuidString).keychain-db")
        // The issuer is a CA of our own under the name of Apple's WWDR G3 intermediate, so zsign, which
        // takes the issuer for its signature from its own copies of Apple's by name, can sign with the leaf
        // (testTheDevicesSignerTakesTheExport). Nothing checks the issuer's signature on that path.
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "2",
                                     "-subj", "/CN=Apple Worldwide Developer Relations Certification Authority/OU=G3/O=Apple Inc./C=US"])
        try run("/usr/bin/openssl", ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "leaf.key", "-out", "leaf.csr",
                                     "-subj", "/CN=Apple Development: Slashplayed Test (ABCDE12345)/OU=ABCDE12345/O=Slashplayed Test/C=US"])
        try run("/usr/bin/openssl", ["x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-set_serial", "2",
                                     "-days", "2", "-out", "leaf.pem"])
        try run("/usr/bin/openssl", ["x509", "-in", "leaf.pem", "-outform", "DER", "-out", "leaf.der"])
        try run("/usr/bin/security", ["create-keychain", "-p", keychainPassword, keychainPath.path])
        try run("/usr/bin/security", ["unlock-keychain", "-p", keychainPassword, keychainPath.path])
        // The key and the certificate on their own (not a .p12), so no PKCS#12 dialect matters; the
        // keychain pairs them into an identity.
        try run("/usr/bin/security", ["import", "leaf.key", "-k", keychainPath.path] + (trusted ? ["-A"] : ["-T", "/usr/bin/security"]))
        try run("/usr/bin/security", ["import", "leaf.pem", "-k", keychainPath.path])
        var keychain: SecKeychain?
        XCTAssertEqual(SecKeychainOpen(keychainPath.path, &keychain), errSecSuccess)
        let list = try run("/usr/bin/security", ["list-keychains"])
        XCTAssertFalse(list.contains(keychainPath.lastPathComponent), "the test keychain is on the search list")
        return (try XCTUnwrap(keychain), DeviceIdentity.sha1(try Data(contentsOf: scratch.appending(path: "leaf.der"))))
    }

    /// What the launcher's import does first (spsign.m), on the Mac: SecPKCS12Import's identities in `p12`.
    /// In memory only: on macOS, SecPKCS12Import otherwise adds what it opens to the default keychain (the
    /// login keychain), which left test identities there. Checks that no keychain on the search list has
    /// the certificate afterwards.
    static func importP12(_ p12: Data, password: String) -> (OSStatus, [[String: Any]]) {
        var items: CFArray?
        let st = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase: password, kSecImportToMemoryOnly: true] as CFDictionary, &items)
        let list = items as? [[String: Any]] ?? []
        // Every certificate the search list holds, by SHA-1 (a match on the imported ref itself would find
        // the in-memory item, kept in no keychain).
        var all: CFTypeRef?
        _ = SecItemCopyMatching([kSecClass: kSecClassCertificate, kSecMatchLimit: kSecMatchLimitAll, kSecReturnData: true] as CFDictionary, &all)
        let kept = Set((all as? [Data] ?? []).map(DeviceIdentity.sha1))
        for item in list {
            guard let identity = item[kSecImportItemIdentity as String] else { continue }
            var cert: SecCertificate?
            XCTAssertEqual(SecIdentityCopyCertificate(identity as! SecIdentity, &cert), errSecSuccess)
            guard let cert else { continue }
            XCTAssertFalse(kept.contains(DeviceIdentity.sha1(SecCertificateCopyData(cert) as Data)),
                           "the .p12's certificate went into a keychain on the search list")
        }
        return (st, list)
    }

    // MARK: Source and setting

    func testSourceByTeamAndOverride() {
        XCTAssertEqual(DeviceIdentity.source(teamIsFree: true, override: nil), .a)
        XCTAssertEqual(DeviceIdentity.source(teamIsFree: false, override: nil), .b)
        XCTAssertEqual(DeviceIdentity.source(teamIsFree: false, override: "A"), .a)
        XCTAssertEqual(DeviceIdentity.source(teamIsFree: true, override: "B"), .b)
        // Anything else is no override.
        XCTAssertEqual(DeviceIdentity.source(teamIsFree: false, override: "a"), .b)
        XCTAssertEqual(DeviceIdentity.source(teamIsFree: true, override: ""), .a)
    }

    func testUpdatesGamesIsOffUntilTurnedOn() throws {
        let suite = "sp-device-identity-tests-\(getpid())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = Device(name: "iPhone", udid: "00008140-TEST", kind: .iPhone)
        XCTAssertEqual(device.updateGamesKey, "updateGames.00008140-TEST")
        XCTAssertFalse(Device.updatesGamesByDefault)
        XCTAssertFalse(device.updatesGames(defaults))
        // Copying settled for known devices doesn't touch it.
        Device.keepCopyingOnKnownDevices([device], defaults)
        XCTAssertFalse(device.updatesGames(defaults))
        device.setUpdatesGames(true, defaults)
        XCTAssertTrue(device.updatesGames(defaults))
        XCTAssertFalse(Device(name: "iPad", udid: "OTHER", kind: .iPad).updatesGames(defaults))
    }

    // MARK: The device's status

    func testStatusLines() {
        typealias S = DeviceIdentity.Status
        XCTAssertEqual(S("present 2027-10-24\n"), S(state: .present, validUntil: "2027-10-24"))
        XCTAssertEqual(S("expired 2026-01-02"), S(state: .expired, validUntil: "2026-01-02"))
        XCTAssertEqual(S("none\n"), S(state: .none))
        XCTAssertEqual(S("forgotten\n"), S(state: .forgotten))
        XCTAssertEqual(S("unreadable\n"), S(state: .unreadable))
        XCTAssertNil(S(""))
        XCTAssertNil(S("present"), "present needs its day")
        XCTAssertNil(S("none 2027-10-24"), "none has no day")
        XCTAssertNil(S("present tomorrow"))
        XCTAssertNil(S("maybe 2027-10-24"))
    }

    func testDayIsUTC() {
        // 2027-10-24 23:30 UTC is already the 25th east of it; the launcher writes the UTC day.
        XCTAssertEqual(DeviceIdentity.day(Date(timeIntervalSince1970: 1_824_420_600)), "2027-10-24")
    }

    // MARK: The decision

    func testDecision() {
        typealias S = DeviceIdentity.Status
        let id = (hash: "AB12", validUntil: "2027-10-24")
        let current = S(state: .present, validUntil: "2027-10-24")
        func decide(on: Bool = true, source: DeviceIdentity.Source = .a, identity: (hash: String, validUntil: String)? = id,
                    pushed: String? = "AB12", pushedSource: DeviceIdentity.Source? = .a, status: S? = current,
                    pending: Bool = false) -> DeviceIdentity.Decision {
            DeviceIdentity.decide(on: on, source: source, identity: identity, pushed: pushed, pushedSource: pushedSource,
                                  status: status, pending: pending)
        }
        func pushes(_ d: DeviceIdentity.Decision) -> Bool { if case .push = d { true } else { false } }
        func nothing(_ d: DeviceIdentity.Decision) -> Bool { if case .nothing = d { true } else { false } }

        // Off: nothing, unless something was sent, which the device is asked to delete.
        XCTAssertTrue(nothing(decide(on: false, pushed: nil)))
        XCTAssertEqual(decide(on: false), .forget)
        XCTAssertEqual(decide(on: false, status: S(state: .forgotten)), .forget)
        // Forgotten on the device: the setting goes off, nothing is pushed back.
        XCTAssertEqual(decide(status: S(state: .forgotten)), .turnOff)
        // Turned on again after that (the record went with the turn-off): sent again.
        XCTAssertTrue(pushes(decide(pushed: nil, status: S(state: .forgotten))))
        // No identity: nothing, for A (no build yet) or B (no Slashplayed certificate set up, or expired).
        XCTAssertTrue(nothing(decide(identity: nil, pushed: nil, status: nil)))
        XCTAssertTrue(nothing(decide(source: .b, identity: nil, pushed: nil, status: nil)))
        // B's certificate decides as A's identity does.
        XCTAssertTrue(pushes(decide(source: .b, pushed: nil, status: nil)))
        XCTAssertTrue(nothing(decide(source: .b)))
        // Switching from A to B: another SHA-1, so it's sent.
        XCTAssertTrue(pushes(decide(source: .b, identity: (hash: "B", validUntil: "2027-10-24"))))
        // Up to date.
        XCTAssertTrue(nothing(decide()))
        // Never sent, or the device can't say: send.
        XCTAssertTrue(pushes(decide(pushed: nil, status: nil)))
        XCTAssertTrue(pushes(decide(status: nil)))
        XCTAssertTrue(pushes(decide(status: S(state: .none))))
        XCTAssertTrue(pushes(decide(status: S(state: .unreadable))))
        XCTAssertTrue(pushes(decide(status: S(state: .expired, validUntil: "2027-10-24"))))
        // Sent and waiting for the launcher: not again, unless the identity changed since.
        XCTAssertTrue(nothing(decide(status: S(state: .none), pending: true)))
        XCTAssertTrue(pushes(decide(pushed: "OLD", status: S(state: .none), pending: true)))
        // Xcode replaced the certificate: the companion's SHA-1 changed.
        XCTAssertEqual(decide(pushed: "OLD"), .push("Xcode replaced the certificate Slashplayed signs with"))
        XCTAssertEqual(decide(source: .b, pushed: "OLD", pushedSource: .b), .push("there's a new Slashplayed certificate"))
        // The source switched (the override set or deleted): it says so, not that Xcode replaced anything.
        XCTAssertEqual(decide(source: .b, identity: (hash: "B", validUntil: "2027-10-24")),
                       .push("the device gets the Slashplayed certificate (B) instead of the identity this Mac signs with (A)"))
        XCTAssertEqual(decide(pushed: "B", pushedSource: .b),
                       .push("the device gets the identity this Mac signs with (A) instead of the Slashplayed certificate (B)"))
        // Nothing on record, but the device holds one.
        XCTAssertEqual(decide(pushed: nil, pushedSource: nil),
                       .push("the device's identity wasn't sent from this Mac since Update Games on This Device was turned on"))
        // The device holds an identity that isn't this one (another Mac's, or an older one).
        XCTAssertTrue(pushes(decide(status: S(state: .present, validUntil: "2026-05-01"))))
    }

    /// The source of what was pushed: the record kept with it, or for a push from before that record, B if it's
    /// the Slashplayed certificate's SHA-1 and A otherwise.
    func testPushedSource() {
        XCTAssertNil(DeviceIdentity.pushedSource(recorded: "A", pushed: nil, certificate: "B1"))
        XCTAssertEqual(DeviceIdentity.pushedSource(recorded: "A", pushed: "B1", certificate: "B1"), .a)
        XCTAssertEqual(DeviceIdentity.pushedSource(recorded: "B", pushed: "A1", certificate: nil), .b)
        XCTAssertEqual(DeviceIdentity.pushedSource(recorded: nil, pushed: "B1", certificate: "B1"), .b)
        XCTAssertEqual(DeviceIdentity.pushedSource(recorded: nil, pushed: "A1", certificate: "B1"), .a)
        XCTAssertEqual(DeviceIdentity.pushedSource(recorded: nil, pushed: "A1", certificate: nil), .a)
        XCTAssertEqual(DeviceIdentity.pushedSource(recorded: "junk", pushed: "B1", certificate: "B1"), .b)
    }

    // MARK: The export

    func testExportsAnIdentityThePasswordOpens() throws {
        let (keychain, hash) = try Self.makeKeychain(trusted: true)
        let password = try DeviceIdentity.newPassword()
        XCTAssertEqual(Data(base64Encoded: password)?.count, 32)
        XCTAssertNotEqual(password, try DeviceIdentity.newPassword())
        let p12 = try DeviceIdentity.export(hash: hash.lowercased(), password: password, keychains: [keychain])
        // What the launcher's import does first (spsign.m): one identity, and the password opens it.
        let (status, list) = Self.importP12(p12, password: password)
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual(list.count, 1)
        let identity = list[0][kSecImportItemIdentity as String] as! SecIdentity
        var cert: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(identity, &cert), errSecSuccess)
        XCTAssertEqual(DeviceIdentity.sha1(SecCertificateCopyData(try XCTUnwrap(cert)) as Data), hash)
        XCTAssertNotEqual(Self.importP12(p12, password: "wrong").0, errSecSuccess)
    }

    /// The device's signer reads what macOS exports (the identity alone, as Keychain Access exports it):
    /// zsign's OpenSSL (scripts/build-zsign.sh), not only SecPKCS12Import, opens the .p12 and signs a fixture
    /// of our own with it and a profile for the team.
    func testTheDevicesSignerTakesTheExport() throws {
        let (keychain, hash) = try Self.makeKeychain(trusted: true)
        let password = try DeviceIdentity.newPassword()
        let p12 = try DeviceIdentity.export(hash: hash, password: password, keychains: [keychain])
        let plist: [String: Any] = [
            "Name": "Slashplayed Test", "TeamIdentifier": ["ABCDE12345"],
            "DeveloperCertificates": [try Data(contentsOf: Self.scratch.appending(path: "leaf.der"))],
            "Entitlements": ["application-identifier": "ABCDE12345.com.strawdynamics.sptest",
                             "com.apple.developer.team-identifier": "ABCDE12345"],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: Self.scratch.appending(path: "profile.plist"))
        try Self.run("/usr/bin/openssl", ["smime", "-sign", "-nodetach", "-binary", "-outform", "DER", "-in", "profile.plist",
                                          "-signer", "leaf.pem", "-inkey", "leaf.key", "-out", "profile.mobileprovision"])
        try "int sp_identity_answer(void) { return 42; }\n".write(to: Self.scratch.appending(path: "fixture.c"), atomically: true, encoding: .utf8)
        try Self.run("/usr/bin/xcrun", ["clang", "-arch", "arm64", "-bundle", "fixture.c", "-o", "fixture.bundle"])
        let dest = Self.scratch.appending(path: "signed.bundle")
        var problem: NSString?
        XCTAssertTrue(sp_sign(Self.scratch.appending(path: "fixture.bundle").path, dest.path, "spidentitytest", p12, password,
                              try Data(contentsOf: Self.scratch.appending(path: "profile.mobileprovision")), &problem),
                      problem as String? ?? "")
        let info = try Self.run("/usr/bin/codesign", ["-d", "-vvvv", dest.path])
        XCTAssertTrue(info.contains("Identifier=spidentitytest"), info)
        XCTAssertTrue(info.contains("TeamIdentifier=ABCDE12345"), info)
    }

    func testExportOfAMissingIdentityFails() throws {
        let (keychain, _) = try Self.makeKeychain(trusted: true)
        XCTAssertThrowsError(try DeviceIdentity.export(hash: String(repeating: "0", count: 40), password: "x", keychains: [keychain])) {
            XCTAssertFalse($0 is DeviceIdentity.Refused, "\($0)")
        }
    }

    /// The key's access list doesn't let this test runner export it, and macOS isn't allowed to ask: the
    /// keychain refuses, as when the person clicks Deny, and that's Refused (Pipeline turns the setting off).
    func testARefusedExportIsRefused() throws {
        let (keychain, hash) = try Self.makeKeychain(trusted: false)
        XCTAssertEqual(SecKeychainSetUserInteractionAllowed(false), errSecSuccess)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        XCTAssertThrowsError(try DeviceIdentity.export(hash: hash, password: "x", keychains: [keychain])) {
            XCTAssertTrue($0 is DeviceIdentity.Refused, "\($0)")
        }
    }

    /// openssl ocsp's answer: good or revoked only once the response's signature verified (Apple's chain).
    func testOCSPAnswers() {
        let file = "/tmp/spstanding-x/leaf.pem"
        XCTAssertEqual(DeviceIdentity.ocspStanding("Response verify OK\n\(file): good\n\tThis Update: Oct 24 17:47:13 2026 GMT\n", certFile: file), .good)
        XCTAssertEqual(DeviceIdentity.ocspStanding("Response verify OK\n\(file): revoked\n\tReason: keyCompromise\n", certFile: file), .revoked)
        XCTAssertEqual(DeviceIdentity.ocspStanding("Response Verify Failure\n\(file): revoked\n", certFile: file),
                       .unknown("Apple's answer couldn't be checked"))
        XCTAssertEqual(DeviceIdentity.ocspStanding("Error querying OCSP responder\n", certFile: file), .unknown("Apple's answer couldn't be checked"))
        XCTAssertEqual(DeviceIdentity.ocspStanding("Response verify OK\n\(file): unknown\n", certFile: file), .unknown("Apple's answer was unknown"))
        XCTAssertEqual(DeviceIdentity.ocspStanding("Response verify OK\nother.pem: good\n", certFile: file), .unknown("Apple gave no answer for it"))
    }

    /// A certificate past its last day is expired without asking anyone.
    func testAnExpiredCertificateNeedsNoAnswer() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sp-standing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", dir.appending(path: "k.pem").path,
                       "-out", dir.appending(path: "c.der").path, "-outform", "DER", "-days", "1", "-subj", "/CN=Slashplayed Test"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, try Data(contentsOf: dir.appending(path: "c.der")) as CFData))
        let end = try XCTUnwrap(SecCertificateCopyNotValidAfterDate(cert) as Date?)
        let standing = await DeviceIdentity.standing(of: cert, now: end.addingTimeInterval(60))
        XCTAssertEqual(standing, .expired(DeviceIdentity.day(end)))
        // Now, a self-signed certificate names no responder and has no issuer to ask about.
        if case .unknown = await DeviceIdentity.standing(of: cert) {} else { XCTFail("a self-signed certificate's standing is unknown") }
    }
}
