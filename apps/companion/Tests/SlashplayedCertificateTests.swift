import Security
import XCTest

/// SlashplayedCertificate (B): the request, the checks on the certificate the person brings back, the
/// export, and whether a profile lists the certificate. Everything runs in keychain files of its own under
/// $TMPDIR (never on the search list, deleted afterwards), with a CA of our own standing in for Apple's; the
/// login keychain and the companion's own store are never touched, and macOS is never allowed to prompt.
final class SlashplayedCertificateTests: XCTestCase {
    static let scratch = FileManager.default.temporaryDirectory.appending(path: "sp-certificate-tests-\(getpid())")
    static let team = "ABCDE12345"
    var stores: [SlashplayedCertificate.Store] = []

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: Self.scratch, withIntermediateDirectories: true)
        SecKeychainSetUserInteractionAllowed(false)
    }

    override func tearDown() {
        for store in stores { _ = try? DeviceIdentityTests.run("/usr/bin/security", ["delete-keychain", store.path.path], in: Self.scratch) }
        try? FileManager.default.removeItem(at: Self.scratch)
        SecKeychainSetUserInteractionAllowed(true)
        super.tearDown()
    }

    /// A new store: a keychain path that hasn't existed in this process, and a random password.
    func makeStore() throws -> SlashplayedCertificate.Store {
        let store = SlashplayedCertificate.Store(path: Self.scratch.appending(path: "b-\(UUID().uuidString).keychain-db"),
                                                 password: try DeviceIdentity.newPassword())
        stores.append(store)
        return store
    }

    @discardableResult
    func openssl(_ args: [String]) throws -> String {
        try DeviceIdentityTests.run("/usr/bin/openssl", args, in: Self.scratch)
    }

    /// Issues a certificate for the request in `csr` from a CA of our own (made once per test), with
    /// Apple's subject layout for a development certificate of `team`. `days` 0: already expired.
    func issue(_ csr: String, team: String = team, out: String) throws {
        let ca = Self.scratch.appending(path: "ca.cnf")
        if !FileManager.default.fileExists(atPath: ca.path) {
            try """
                [ca]
                default_ca = test
                [test]
                dir = .
                database = index.txt
                serial = serial
                new_certs_dir = .
                default_md = sha256
                policy = anything
                unique_subject = no
                [anything]
                commonName = optional
                organizationalUnitName = optional
                organizationName = optional
                countryName = optional
                """.write(to: ca, atomically: true, encoding: .utf8)
            try "".write(to: Self.scratch.appending(path: "index.txt"), atomically: true, encoding: .utf8)
            try "02\n".write(to: Self.scratch.appending(path: "serial"), atomically: true, encoding: .utf8)
            try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "2",
                         "-subj", "/CN=Apple Worldwide Developer Relations Certification Authority/OU=G3/O=Apple Inc./C=US"])
        }
        try openssl(["ca", "-config", "ca.cnf", "-batch", "-notext", "-in", csr, "-cert", "ca.pem", "-keyfile", "ca.key", "-days", "2",
                     "-subj", "/CN=Apple Development: Slashplayed Test (\(team))/OU=\(team)/O=Slashplayed Test/C=US", "-out", out])
        try openssl(["x509", "-in", out, "-outform", "DER", "-out", out + ".der"])
    }

    func data(_ name: String) throws -> Data { try Data(contentsOf: Self.scratch.appending(path: name)) }

    /// A request for the store's key, saved as `name`.
    func request(_ store: SlashplayedCertificate.Store, _ name: String = "sp.csr") throws -> Data {
        let pem = try SlashplayedCertificate.request(store)
        try pem.write(to: Self.scratch.appending(path: name))
        return pem
    }

    // MARK: The request

    func testTheRequestIsAValidRequestForAKeyKeptApart() throws {
        let store = try makeStore()
        XCTAssertEqual(try SlashplayedCertificate.state(of: store), .none)
        let pem = try request(store)
        XCTAssertEqual(try SlashplayedCertificate.state(of: store), .requested)
        // openssl checks the request's signature against the key in it.
        let text = try openssl(["req", "-in", "sp.csr", "-verify", "-noout", "-subject"])
        XCTAssertTrue(text.contains("verify OK"), text)
        XCTAssertTrue(text.contains("CN=Slashplayed") || text.contains("CN = Slashplayed"), text)
        let key = try openssl(["req", "-in", "sp.csr", "-noout", "-text"])
        XCTAssertTrue(key.contains("2048 bit"), key)
        XCTAssertTrue(key.contains("sha256WithRSAEncryption"), key)
        // The same key, so the same request: asking again is harmless.
        XCTAssertEqual(try SlashplayedCertificate.request(store), pem)
        // The keychain file is 0600 and off the search list, and the key is found only by naming it.
        let mode = try FileManager.default.attributesOfItem(atPath: store.path.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let list = try DeviceIdentityTests.run("/usr/bin/security", ["list-keychains"], in: Self.scratch)
        XCTAssertFalse(list.contains(store.path.lastPathComponent), list)
        var found: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching([kSecClass: kSecClassKey, kSecAttrLabel: SlashplayedCertificate.label,
                                            kSecReturnRef: true] as CFDictionary, &found), errSecItemNotFound)
    }

    func testDERLengths() {
        XCTAssertEqual(DER.tagged(0x04, Data(count: 3)).prefix(2), Data([0x04, 0x03]))
        XCTAssertEqual(DER.tagged(0x04, Data(count: 0x80)).prefix(3), Data([0x04, 0x81, 0x80]))
        XCTAssertEqual(DER.tagged(0x04, Data(count: 0x1234)).prefix(4), Data([0x04, 0x82, 0x12, 0x34]))
    }

    // MARK: The certificate

    func testTakesTheTeamsCertificateForTheKey() throws {
        let store = try makeStore()
        try request(store)
        try issue("sp.csr", out: "sp.pem")
        let cert = try SlashplayedCertificate.add(try data("sp.pem.der"), team: Self.team, to: store)
        XCTAssertEqual(cert.hash, DeviceIdentity.sha1(try data("sp.pem.der")))
        XCTAssertTrue(cert.name.contains("Apple Development: Slashplayed Test"), cert.name)
        XCTAssertEqual(try SlashplayedCertificate.state(of: store), .ready(cert))
        // PEM too, and again (already kept) is fine.
        XCTAssertEqual(try SlashplayedCertificate.add(try data("sp.pem"), team: Self.team, to: store), cert)
    }

    func testRefusesAnotherTeamsAnotherKeysAndExpiredCertificates() throws {
        let store = try makeStore()
        try request(store)
        // Another team's.
        try issue("sp.csr", team: "ZZZZZ99999", out: "other-team.pem")
        XCTAssertThrowsError(try SlashplayedCertificate.add(try data("other-team.pem.der"), team: Self.team, to: store)) {
            XCTAssertTrue($0.localizedDescription.contains("ZZZZZ99999"), $0.localizedDescription)
        }
        // Another key's (a request openssl made).
        try openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "x.key", "-out", "x.csr", "-subj", "/CN=x"])
        try issue("x.csr", out: "other-key.pem")
        XCTAssertThrowsError(try SlashplayedCertificate.add(try data("other-key.pem.der"), team: Self.team, to: store)) {
            XCTAssertTrue($0.localizedDescription.contains("request"), $0.localizedDescription)
        }
        // The right one, but checked after it runs out.
        try issue("sp.csr", out: "sp.pem")
        XCTAssertThrowsError(try SlashplayedCertificate.add(try data("sp.pem.der"), team: Self.team, to: store,
                                                            now: Date().addingTimeInterval(3 * 24 * 3600))) {
            XCTAssertTrue($0.localizedDescription.contains("expired"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try SlashplayedCertificate.add(Data("not a certificate".utf8), team: Self.team, to: store))
        XCTAssertEqual(try SlashplayedCertificate.state(of: store), .requested, "nothing refused was kept")
    }

    func testNoKeyNoCertificate() throws {
        let store = try makeStore()
        try request(store)
        try issue("sp.csr", out: "sp.pem")
        let empty = try makeStore()
        XCTAssertThrowsError(try SlashplayedCertificate.add(try data("sp.pem.der"), team: Self.team, to: empty))
    }

    // MARK: The export

    /// What a push sends: the store's identity alone, which the password opens, exported with macOS's prompts
    /// off (so with no prompt: this process made the key).
    func testExportsTheIdentityWithoutAsking() throws {
        let store = try makeStore()
        try request(store)
        try issue("sp.csr", out: "sp.pem")
        let cert = try SlashplayedCertificate.add(try data("sp.pem.der"), team: Self.team, to: store)
        let password = try DeviceIdentity.newPassword()
        let p12 = try SlashplayedCertificate.export(store, hash: cert.hash, password: password)
        let (status, list) = DeviceIdentityTests.importP12(p12, password: password)
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual(list.count, 1)
        var leaf: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(list[0][kSecImportItemIdentity as String] as! SecIdentity, &leaf), errSecSuccess)
        XCTAssertEqual(DeviceIdentity.sha1(SecCertificateCopyData(try XCTUnwrap(leaf)) as Data), cert.hash)
    }

    // MARK: Another copy's key

    /// Puts a key made outside the companion (PEM, from openssl) into the store, labelled as its own, with an
    /// access list that trusts only `app`: what a key another copy of the companion made looks like to this one.
    func importKey(_ pem: Data, trusting app: String, into store: SlashplayedCertificate.Store) throws {
        try SlashplayedCertificate.withKeychain(store, create: true) { keychain in
            var trusted: SecTrustedApplication?
            XCTAssertEqual(SecTrustedApplicationCreateFromPath(app, &trusted), errSecSuccess)
            var access: SecAccess?
            XCTAssertEqual(SecAccessCreate(SlashplayedCertificate.label as CFString, [try XCTUnwrap(trusted)] as CFArray, &access), errSecSuccess)
            var params = SecItemImportExportKeyParameters()
            params.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
            params.accessRef = Unmanaged.passUnretained(try XCTUnwrap(access))
            var format = SecExternalFormat.formatUnknown, type = SecExternalItemType.itemTypePrivateKey
            var items: CFArray?
            let st = withExtendedLifetime(access) {
                SecItemImport(pem as CFData, nil, &format, &type, [], &params, keychain, &items)
            }
            XCTAssertEqual(st, errSecSuccess)
            let key = try XCTUnwrap((items as? [SecKey])?.first)
            XCTAssertEqual(SecItemUpdate([kSecValueRef: key] as CFDictionary, [kSecAttrLabel: SlashplayedCertificate.label] as CFDictionary), errSecSuccess)
        }
    }

    /// A key in the companion's store that another copy made (rc9: a dev build's, opened by a release): macOS
    /// refuses this copy every use of it with prompts off, so the state says so before and after the
    /// certificate is added, no request is made from it, and its export is refused, not tried with a prompt.
    func testAnotherCopysKeyIsSaidSo() throws {
        let store = try makeStore()
        try openssl(["genrsa", "-out", "other.key", "2048"])
        try openssl(["req", "-new", "-key", "other.key", "-subj", "/CN=Slashplayed", "-out", "other.csr"])
        try importKey(try data("other.key"), trusting: "/usr/bin/true", into: store)
        XCTAssertEqual(try SlashplayedCertificate.state(of: store), .otherCopy(nil))
        XCTAssertThrowsError(try SlashplayedCertificate.request(store)) {
            XCTAssertEqual($0.localizedDescription, SlashplayedCertificate.otherCopyFix)
        }
        try issue("other.csr", out: "other.pem")
        let cert = try SlashplayedCertificate.add(try data("other.pem.der"), team: Self.team, to: store)
        XCTAssertEqual(try SlashplayedCertificate.state(of: store), .otherCopy(cert))
        XCTAssertThrowsError(try SlashplayedCertificate.export(store, hash: cert.hash, password: try DeviceIdentity.newPassword())) {
            XCTAssertTrue($0 is DeviceIdentity.Refused, "\($0)")
        }
    }

    /// The store's own key, which this copy made, is usable.
    func testThisCopysKeyIsUsable() throws {
        let store = try makeStore()
        try request(store)
        XCTAssertEqual(try SlashplayedCertificate.state(of: store), .requested)
    }

    // MARK: Profiles

    func testWhetherAProfileListsTheCertificate() throws {
        let store = try makeStore()
        try request(store)
        try issue("sp.csr", out: "sp.pem")
        let der = try data("sp.pem.der")
        let hash = DeviceIdentity.sha1(der)
        func profile(_ certs: [Data]) throws -> Data {
            let plist: [String: Any] = ["UUID": UUID().uuidString, "TeamIdentifier": [Self.team], "DeveloperCertificates": certs,
                                        "ExpirationDate": Date().addingTimeInterval(86400)]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: Self.scratch.appending(path: "profile.plist"))
            // In a CMS envelope, as a device installs it (signed by our CA, standing in for Apple).
            try openssl(["smime", "-sign", "-nodetach", "-binary", "-outform", "DER", "-in", "profile.plist",
                         "-signer", "ca.pem", "-inkey", "ca.key", "-out", "profile.mobileprovision"])
            return try data("profile.mobileprovision")
        }
        let other = SecCertificateCopyData(try XCTUnwrap(SlashplayedCertificate.certificate(from: data("ca.pem")))) as Data
        XCTAssertTrue(SlashplayedCertificate.lists(profile: try profile([other, der]), hash: hash))
        XCTAssertTrue(SlashplayedCertificate.lists(profile: try profile([der]), hash: hash.lowercased()))
        XCTAssertFalse(SlashplayedCertificate.lists(profile: try profile([other]), hash: hash))
        XCTAssertFalse(SlashplayedCertificate.lists(profile: try profile([]), hash: hash))
        XCTAssertFalse(SlashplayedCertificate.lists(profile: Data("junk".utf8), hash: hash))
    }
}
