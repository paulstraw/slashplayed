import XCTest

/// The launcher's signer (apps/client/spsign.m, zsign through spzsign.cpp), run on the Mac: it signs a
/// fixture of our own (an MH_BUNDLE, like the client image) with a throwaway identity made here, and
/// codesign reads the signature back. The identity is a self-made CA and a certificate it issued, shaped like
/// an Apple Development one, with a profile for its team signed by it; all of it lives in a scratch folder
/// under $TMPDIR and is deleted afterwards. Nothing touches a keychain.
final class DeviceSigningTests: XCTestCase {
    static let scratch = FileManager.default.temporaryDirectory.appending(path: "sp-device-signing-tests-\(getpid())")
    static let team = "ABCDE12345"
    static let commonName = "Apple Development: Slashplayed Test (ABCDE12345)"
    static var fixture: URL { scratch.appending(path: "fixture.bundle") }
    static var p12: URL { scratch.appending(path: "identity.p12") }
    static var profile: URL { scratch.appending(path: "embedded.mobileprovision") }
    /// Random for each run, like the companion's per-push password.
    static let password = UUID().uuidString

    override class func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: scratch)
        try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try! makeIdentity()
        try! makeSecondIdentity()
        try! makeFixture()
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = scratch
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw Failure("\(tool) \(args.first ?? "") failed: \(text)") }
        return text
    }

    /// The CA, the certificate it issues (the subject's CN and OU are what Apple's carry: the name and the
    /// team), the .p12 with the CA in its chain (zsign embeds the issuer from it: this one isn't Apple's), and
    /// a profile for the team listing the certificate, CMS-signed as a real one is (zsign reads its content).
    static func makeIdentity() throws {
        let openssl = "/usr/bin/openssl"
        try "\(password)\n".write(to: scratch.appending(path: "pass"), atomically: true, encoding: .utf8)
        try run(openssl, ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem",
                          "-days", "2", "-subj", "/CN=Slashplayed Test CA"])
        try run(openssl, ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "leaf.key", "-out", "leaf.csr",
                          "-subj", "/CN=\(commonName)/OU=\(team)/O=Slashplayed Test/C=US"])
        try run(openssl, ["x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-set_serial", "2",
                          "-days", "2", "-out", "leaf.pem"])
        try run(openssl, ["pkcs12", "-export", "-inkey", "leaf.key", "-in", "leaf.pem", "-certfile", "ca.pem",
                          "-out", p12.path, "-passout", "file:pass"])
        try run(openssl, ["x509", "-in", "leaf.pem", "-outform", "DER", "-out", "leaf.der"])
        let plist: [String: Any] = [
            "Name": "Slashplayed Test", "TeamIdentifier": [team], "ExpirationDate": Date(timeIntervalSinceNow: 2 * 24 * 3600),
            "DeveloperCertificates": [try Data(contentsOf: scratch.appending(path: "leaf.der"))],
            "Entitlements": ["application-identifier": "\(team).com.strawdynamics.sptest",
                             "com.apple.developer.team-identifier": team, "get-task-allow": true],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: scratch.appending(path: "profile.plist"))
        try run(openssl, ["smime", "-sign", "-nodetach", "-binary", "-outform", "DER", "-in", "profile.plist",
                          "-signer", "leaf.pem", "-inkey", "leaf.key", "-out", profile.path])
    }

    /// Another certificate of the team from the same CA, with its own key (Xcode's replacement for A, or the
    /// Slashplayed certificate, B), as second.p12 and second.der.
    static var secondP12: URL { scratch.appending(path: "second.p12") }
    static func makeSecondIdentity() throws {
        let openssl = "/usr/bin/openssl"
        try run(openssl, ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "second.key", "-out", "second.csr",
                          "-subj", "/CN=Apple Development: Slashplayed Test Two (ABCDE12345)/OU=\(team)/O=Slashplayed Test/C=US"])
        try run(openssl, ["x509", "-req", "-in", "second.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-set_serial", "3",
                          "-days", "2", "-out", "second.pem"])
        try run(openssl, ["pkcs12", "-export", "-inkey", "second.key", "-in", "second.pem", "-certfile", "ca.pem",
                          "-out", secondP12.path, "-passout", "file:pass"])
        try run(openssl, ["x509", "-in", "second.pem", "-outform", "DER", "-out", "second.der"])
    }

    /// A profile of the test team listing `certificates`, expiring at `expires`, CMS-signed like makeIdentity's.
    static func profile(listing certificates: [Data], expires: Date, name: String) throws -> Data {
        let plist: [String: Any] = ["Name": name, "TeamIdentifier": [team], "ExpirationDate": expires, "DeveloperCertificates": certificates]
        let file = scratch.appending(path: "\(name).plist"), out = scratch.appending(path: "\(name).mobileprovision")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: file)
        try run("/usr/bin/openssl", ["smime", "-sign", "-nodetach", "-binary", "-outform", "DER", "-in", file.path,
                                     "-signer", "leaf.pem", "-inkey", "leaf.key", "-out", out.path])
        return try Data(contentsOf: out)
    }

    /// An arm64 MH_BUNDLE of our own code (a function, as research/dlopentest's bundle.c), signed only by
    /// the linker, as the launcher's assembly leaves a client image with a stale signature to replace.
    static func makeFixture() throws {
        let source = scratch.appending(path: "fixture.c")
        try "int sp_sign_answer(void) { return 42; }\n".write(to: source, atomically: true, encoding: .utf8)
        try run("/usr/bin/xcrun", ["clang", "-arch", "arm64", "-bundle", "-O1", source.path, "-o", fixture.path])
    }

    /// One blob's contents (after its magic and length) from the image's code signature superblob.
    static func signatureBlob(_ image: Data, type: UInt32) throws -> Data {
        func be(_ o: Int) -> Int { Int(image[image.startIndex + o ..< image.startIndex + o + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) }
        var sig: Int?
        try MachO.forEachCommand(image) { cmd, off in if cmd == 0x1D { sig = Int(MachO.u32(image, off + 8)) } }
        let base = try XCTUnwrap(sig, "no LC_CODE_SIGNATURE")
        for i in 0..<be(base + 8) where be(base + 12 + i * 8) == Int(type) {
            let blob = base + be(base + 16 + i * 8)
            return image.subdata(in: image.startIndex + blob + 8 ..< image.startIndex + blob + be(blob + 4))
        }
        throw Failure("no blob of type \(type)")
    }

    /// The blob types in the image's code signature superblob (LC_CODE_SIGNATURE's), in order.
    static func signatureSlots(_ image: Data) throws -> [UInt32] {
        func le(_ o: Int) -> UInt32 { MachO.u32(image, o) }
        func be(_ o: Int) -> UInt32 { image[image.startIndex + o ..< image.startIndex + o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        var sig: Int?
        try MachO.forEachCommand(image) { cmd, off in if cmd == 0x1D { sig = Int(le(off + 8)) } }
        let base = try XCTUnwrap(sig, "no LC_CODE_SIGNATURE")
        XCTAssertEqual(be(base), 0xFADE_0CC0, "not an embedded signature superblob")
        return (0..<Int(be(base + 8))).map { be(base + 12 + $0 * 8) }
    }

    /// Files in the scratch folder whose names say they're the signer's leftovers.
    static func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter { $0.hasSuffix(".signing") || $0.hasSuffix(".signed") }
    }

    func testSignsWithTheIdentity() throws {
        let dest = Self.scratch.appending(path: "signed.bundle")
        let before = try Data(contentsOf: Self.fixture)
        var problem: NSString?
        let ok = sp_sign(Self.fixture.path, dest.path, "spsigntest", try Data(contentsOf: Self.p12), Self.password,
                         try Data(contentsOf: Self.profile), &problem)
        XCTAssertTrue(ok, problem as String? ?? "")
        XCTAssertEqual(try Data(contentsOf: Self.fixture), before, "the source changed")
        XCTAssertEqual(try Self.leftovers(), [])
        let info = try Self.run("/usr/bin/codesign", ["-d", "-vvvv", dest.path])
        XCTAssertTrue(info.contains("Identifier=spsigntest"), info)
        XCTAssertTrue(info.contains("TeamIdentifier=\(Self.team)"), info)
        // The CMS signer and its chain: the identity's certificate, then the issuer from the .p12. (codesign
        // shows neither for a chain the Mac doesn't trust, "Authority=(unavailable)", so the blob is read.)
        let cms = Self.scratch.appending(path: "cms.der")
        try Self.signatureBlob(Data(contentsOf: dest), type: 0x10000).write(to: cms)
        let chain = try Self.run("/usr/bin/openssl", ["pkcs7", "-inform", "DER", "-print_certs", "-noout", "-in", cms.path])
        XCTAssertTrue(chain.contains("subject=/CN=\(Self.commonName)"), chain)
        XCTAssertTrue(chain.contains("subject=/CN=Slashplayed Test CA"), chain)
        // The designated requirement names the certificate as codesign's does for a development identity.
        let requirement = try Self.run("/usr/bin/codesign", ["-d", "-r-", dest.path])
        XCTAssertTrue(requirement.contains("designated => identifier spsigntest and anchor apple generic"), requirement)
        XCTAssertTrue(requirement.contains("certificate leaf[subject.CN] = \"\(Self.commonName)\""), requirement)
        // Both code directories, as codesign writes them: SHA-1 and SHA-256.
        XCTAssertTrue(info.contains("CandidateCDHash sha1="), info)
        XCTAssertTrue(info.contains("CandidateCDHash sha256="), info)
        // No entitlements in a non-executable's signature (scripts/zsign.patch): iOS refuses an image with
        // them, even empty. The code directory, the requirements, an alternate code directory, and the CMS.
        let slots = try Self.signatureSlots(Data(contentsOf: dest))
        XCTAssertFalse(slots.contains(5), "an entitlements blob: \(slots)")
        XCTAssertFalse(slots.contains(7), "a DER entitlements blob: \(slots)")
        XCTAssertTrue(slots.contains(0) && slots.contains(2) && slots.contains(0x1000) && slots.contains(0x10000), "\(slots)")
        let ents = try Self.run("/usr/bin/codesign", ["-d", "--entitlements", "-", dest.path])
        XCTAssertFalse(ents.contains("<dict"), ents)
        // (Whether it loads is the device's to say: the Mac refuses a chain it doesn't trust in dlopen, and
        // the device a certificate no installed profile lists. apps/client/push-identity.sh tests that there.)
    }

    /// The image the launcher signs carries a signature already (the client's stale one), and an unsigned
    /// one gets the room for one.
    func testSignsAnUnsignedImage() throws {
        let unsigned = Self.scratch.appending(path: "unsigned.bundle"), dest = Self.scratch.appending(path: "signed-unsigned.bundle")
        try FileManager.default.copyItem(at: Self.fixture, to: unsigned)
        try Self.run("/usr/bin/codesign", ["--remove-signature", unsigned.path])
        var problem: NSString?
        XCTAssertTrue(sp_sign(unsigned.path, dest.path, "spsigntest", try Data(contentsOf: Self.p12), Self.password,
                              try Data(contentsOf: Self.profile), &problem), problem as String? ?? "")
        XCTAssertTrue(try Self.run("/usr/bin/codesign", ["-d", "-vvvv", dest.path]).contains("TeamIdentifier=\(Self.team)"))
    }

    /// zsign's messages, warnings and errors both, are plain text (scripts/zsign.patch): no terminal color codes
    /// in the launcher's log, where they made grep take console.txt and spconsole.log for binary.
    func testZsignsMessagesHaveNoColorCodes() throws {
        let p12 = try Data(contentsOf: Self.p12), profile = try Data(contentsOf: Self.profile)
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]) }
        // The stale signature has too little room (a warning, and one when it's made), then a wrong password (an error).
        for (password, rc) in [(Self.password, Int32(0)), ("not the password", 1)] {
            let work = Self.scratch.appending(path: "colors.bundle")
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.copyItem(at: Self.fixture, to: work)
            let got = p12.withUnsafeBytes { key in
                profile.withUnsafeBytes { prof in
                    sp_zsign(work.path, "spsigntest", key.baseAddress, key.count, password, prof.baseAddress, prof.count, fds[1])
                }
            }
            XCTAssertEqual(got, rc)
            try FileManager.default.removeItem(at: work)
        }
        close(fds[1])
        let log = FileHandle(fileDescriptor: fds[0]).readDataToEndOfFile()
        XCTAssertTrue(String(decoding: log, as: UTF8.self).contains(">>> "), "zsign said nothing: the test checks nothing")
        XCTAssertFalse(log.contains(0x1B), String(decoding: log, as: UTF8.self))
    }

    func testRefusesAWrongPassword() throws {
        let dest = Self.scratch.appending(path: "never.bundle")
        var problem: NSString?
        XCTAssertFalse(sp_sign(Self.fixture.path, dest.path, "spsigntest", try Data(contentsOf: Self.p12), "not the password",
                               try Data(contentsOf: Self.profile), &problem))
        XCTAssertNotNil(problem)
        XCTAssertFalse((problem as String? ?? "").contains(Self.password))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(try Self.leftovers(), [])
    }

    /// Without the team's profile zsign has no team to sign for.
    func testRefusesWithoutAProfile() throws {
        let dest = Self.scratch.appending(path: "never2.bundle")
        var problem: NSString?
        XCTAssertFalse(sp_sign(Self.fixture.path, dest.path, "spsigntest", try Data(contentsOf: Self.p12), Self.password,
                               Data("not a profile".utf8), &problem))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(try Self.leftovers(), [])
    }

    func testRefusesAMissingSource() throws {
        let dest = Self.scratch.appending(path: "never3.bundle")
        var problem: NSString?
        XCTAssertFalse(sp_sign(Self.scratch.appending(path: "nothing").path, dest.path, "spsigntest", try Data(contentsOf: Self.p12),
                               Self.password, try Data(contentsOf: Self.profile), &problem))
        XCTAssertTrue((problem as String? ?? "").contains("nothing to sign"), problem as String? ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    // MARK: Which certificate an image is signed with (launcher.m's library_signed)

    /// A signed image's certificates are its CMS blob's: the signer's and its issuer (from the .p12), in the
    /// SET's DER order.
    func testAnImagesCertificatesAreItsSignersAndIssuers() throws {
        let dest = Self.scratch.appending(path: "certs.bundle")
        var problem: NSString?
        XCTAssertTrue(sp_sign(Self.fixture.path, dest.path, "spsigntest", try Data(contentsOf: Self.p12), Self.password,
                              try Data(contentsOf: Self.profile), &problem), problem as String? ?? "")
        let certs = sp_image_certificates(dest.path)
        let leaf = try Data(contentsOf: Self.scratch.appending(path: "leaf.der"))
        try Self.run("/usr/bin/openssl", ["x509", "-in", "ca.pem", "-outform", "DER", "-out", "ca.der"])
        XCTAssertEqual(Set(certs), [leaf, try Data(contentsOf: Self.scratch.appending(path: "ca.der"))])
        XCTAssertEqual(certs.count, 2)
    }

    /// The linker's ad hoc signature and no signature at all have no certificate; nor has a file that isn't a Mach-O.
    func testAdHocUnsignedAndGarbageHaveNoCertificates() throws {
        XCTAssertEqual(sp_image_certificates(Self.fixture.path), [], "the linker's ad hoc signature")
        let unsigned = Self.scratch.appending(path: "nocerts.bundle")
        try? FileManager.default.removeItem(at: unsigned)
        try FileManager.default.copyItem(at: Self.fixture, to: unsigned)
        try Self.run("/usr/bin/codesign", ["--remove-signature", unsigned.path])
        XCTAssertEqual(sp_image_certificates(unsigned.path), [])
        let text = Self.scratch.appending(path: "text.bundle")
        try Data("not a mach-o".utf8).write(to: text)
        XCTAssertEqual(sp_image_certificates(text.path), [])
        XCTAssertEqual(sp_image_certificates(Self.scratch.appending(path: "missing").path), [])
    }

    /// A profile's DeveloperCertificates, while it's valid; an expired profile or something else lists none.
    func testAProfilesCertificates() throws {
        let leaf = try Data(contentsOf: Self.scratch.appending(path: "leaf.der"))
        let second = try Data(contentsOf: Self.scratch.appending(path: "second.der"))
        XCTAssertEqual(sp_profile_certificates(try Data(contentsOf: Self.profile), Date()), [leaf])
        let both = try Self.profile(listing: [leaf, second], expires: Date(timeIntervalSinceNow: 3600), name: "both")
        XCTAssertEqual(sp_profile_certificates(both, Date()), [leaf, second])
        XCTAssertEqual(sp_profile_certificates(both, Date(timeIntervalSinceNow: 7200)), [], "expired by then")
        let expired = try Self.profile(listing: [leaf], expires: Date(timeIntervalSinceNow: -60), name: "expired")
        XCTAssertEqual(sp_profile_certificates(expired, Date()), [])
        XCTAssertEqual(sp_profile_certificates(Data("not a profile".utf8), Date()), [])
    }

    /// The launcher's decision for an update's image: its signer is listed, or isn't (another certificate's
    /// profile, as after Xcode replaced A's), and once signed again in place with an identity that profile lists,
    /// it is. The identity's own certificate is checked the same way (sp_identity_usable).
    func testTheSignerIsListedOrNot() throws {
        let image = Self.scratch.appending(path: "update.bundle")
        var problem: NSString?
        XCTAssertTrue(sp_sign(Self.fixture.path, image.path, "wow-test", try Data(contentsOf: Self.p12), Self.password,
                              try Data(contentsOf: Self.profile), &problem), problem as String? ?? "")
        let leaf = try Data(contentsOf: Self.scratch.appending(path: "leaf.der"))
        let second = try Data(contentsOf: Self.scratch.appending(path: "second.der"))
        let listsSecond = sp_profile_certificates(try Self.profile(listing: [second], expires: Date(timeIntervalSinceNow: 3600),
                                                                   name: "second-only"), Date())
        XCTAssertTrue(sp_certificates_listed(sp_image_certificates(image.path), [leaf]))
        XCTAssertFalse(sp_certificates_listed(sp_image_certificates(image.path), listsSecond))
        XCTAssertFalse(sp_certificates_listed(sp_image_certificates(image.path), []))
        XCTAssertTrue(sp_certificates_listed([second], listsSecond), "the identity to sign it again with")
        // Signed again in place, as library_signed does, with the second identity.
        XCTAssertTrue(sp_sign(image.path, image.path, "wow-test", try Data(contentsOf: Self.secondP12), Self.password,
                              try Data(contentsOf: Self.profile), &problem), problem as String? ?? "")
        XCTAssertEqual(try Self.leftovers(), [])
        XCTAssertTrue(sp_certificates_listed(sp_image_certificates(image.path), listsSecond))
        XCTAssertFalse(sp_certificates_listed(sp_image_certificates(image.path), [leaf]))
        XCTAssertTrue(try Self.run("/usr/bin/codesign", ["-d", "-vvvv", image.path]).contains("Identifier=wow-test"))
    }

    /// The identity's reading (sp_identity_read), which the launcher's log line, the companion's
    /// Library/spidentity.txt, and the Settings sheet share: each state, from the .p12 and password alone.
    func testTheIdentitysReading() throws {
        let p12 = try Data(contentsOf: Self.p12), pass = Data("\(Self.password)\n".utf8)
        let leaf = try Data(contentsOf: Self.scratch.appending(path: "leaf.der"))
        let second = try Data(contentsOf: Self.scratch.appending(path: "second.der"))

        let none = sp_identity_read(nil, nil, false, [], Date())
        XCTAssertEqual(none.state, .none)
        XCTAssertEqual(none.status, "none")
        XCTAssertNil(none.notAfter)
        let forgotten = sp_identity_read(nil, pass, true, [leaf], Date())
        XCTAssertEqual(forgotten.state, .forgotten)
        XCTAssertEqual(forgotten.status, "forgotten")

        let listed = sp_identity_read(p12, pass, true, [second, leaf], Date())
        XCTAssertEqual(listed.state, .present, "an identity there outranks an old forget")
        XCTAssertTrue(listed.listed)
        let notAfter = try XCTUnwrap(listed.notAfter)
        XCTAssertGreaterThan(notAfter, Date(timeIntervalSinceNow: 3600), "the certificate is good for two days")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(listed.status, "present \(f.string(from: notAfter))")
        XCTAssertTrue(listed.line.contains("listed in the app's profiles"), listed.line)

        let unlisted = sp_identity_read(p12, pass, false, [second], Date())
        XCTAssertEqual(unlisted.state, .present)
        XCTAssertFalse(unlisted.listed)

        let expired = sp_identity_read(p12, pass, false, [leaf], Date(timeIntervalSinceNow: 3 * 24 * 3600))
        XCTAssertEqual(expired.state, .expired)
        XCTAssertEqual(expired.status, "expired \(f.string(from: notAfter))")

        for (badP12, badPass) in [(p12, Data("not the password".utf8)), (Data("not a p12".utf8), pass)] {
            let unreadable = sp_identity_read(badP12, badPass, false, [leaf], Date())
            XCTAssertEqual(unreadable.state, .unreadable)
            XCTAssertEqual(unreadable.status, "unreadable")
            XCTAssertNil(unreadable.notAfter)
        }

        // Dates only: no line or status names the certificate or the team.
        for r in [none, forgotten, listed, unlisted, expired] {
            XCTAssertFalse(r.line.contains("Slashplayed Test") || r.status.contains("Slashplayed Test"), r.line)
            XCTAssertFalse(r.line.contains(Self.team) || r.status.contains(Self.team), r.line)
        }
    }
}
