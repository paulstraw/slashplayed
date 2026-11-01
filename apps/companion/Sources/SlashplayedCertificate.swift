import Foundation
import Security

/// Option B's signing identity (DeviceIdentity: a paid team's): an Apple Development certificate of
/// Slashplayed's own, so the key a device signs game updates with isn't the one this Mac signs everything
/// else with, and it can be dropped (and revoked) on its own.
///
/// The companion makes the key (RSA-2048) and a certificate signing request; the person uploads the request
/// on developer.apple.com (Certificates > + > Apple Development) and gives the companion the .cer they
/// download, which is checked against the key and the team and kept beside it. Key and certificate live in a
/// keychain file of the companion's own under Application Support, never on the user's search list: Xcode and
/// codesign look for identities only there (research/dlopentest, 5.3), so neither ever signs with this one,
/// and nothing else finds it. The keychain's password is random, kept as a generic password in the login
/// keychain (readable by this app without asking). The keychain is unlocked only around each use and locked
/// again after, with macOS's prompts off meanwhile: a locked keychain would otherwise ask for its password.
/// The key's access list is the default one (the copy of this app that made it may use it), so the export a push
/// needs (DeviceIdentity) asks nothing; another copy can't use it at all (`.otherCopy`).
///
/// A device can use the identity only once some provisioning profile installed there lists the certificate
/// (5.3); Pipeline sees to that before each push (`lists`). Logs give the certificate's name and last valid
/// day at most, never its SHA-1, the key, or the password.
enum SlashplayedCertificate {
    /// The key's label in the keychain, and the request's subject. Apple ignores the subject and names the
    /// certificate after the account.
    static let label = "Slashplayed"
    /// Where the request is saved for the person to upload.
    static var requestFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads/Slashplayed.certSigningRequest")
    }
    /// Where on developer.apple.com a new certificate is made.
    static let portalURL = URL(string: "https://developer.apple.com/account/resources/certificates/add")!

    /// A keychain file and its password.
    struct Store {
        let path: URL
        let password: String
    }

    /// The certificate the companion keeps, said for the log and Settings.
    struct Certificate: Equatable {
        let hash: String
        let name: String
        /// Its last valid day (DeviceIdentity.day), as the device reports it.
        let validUntil: String
        let expires: Date
    }

    enum State: Equatable {
        /// Nothing made yet.
        case none
        /// The key and its request are made; no certificate yet.
        case requested
        case ready(Certificate)
        /// A key (and its certificate, once added) that another copy of the companion made: one signed
        /// differently, such as a build of the person's own and a release. macOS gives the key's access list
        /// to the copy that made the key, so this one is refused every use with prompts off (errSecAuthFailed,
        /// -25293, rc9). The keychain's password can't change that list: changing it needs a prompt even for
        /// the copy that made the key (-128, prompts off), and nobody knows the password a prompt would ask
        /// for. The only way on is a new key: Stop Using It, then a new request.
        case otherCopy(Certificate?)
    }

    /// What to do about `.otherCopy`, for Settings and the errors here.
    static let otherCopyFix = "Stop using the Slashplayed certificate, then make a new one. Another copy of Slashplayed Companion made its key (one signed differently, such as a build of your own), and macOS lets only that copy use it."

    // MARK: The companion's store

    /// The folder holding the keychain file. One file at a time, named afresh each time one is made: a
    /// keychain deleted and made again at the same path is still the deleted one to this process.
    static var folder: URL {
        let dir = Paths.support.appending(path: "certificate")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// The generic password's service in the login keychain; its account is the keychain file's name.
    static let passwordService = "Slashplayed certificate keychain"

    /// The companion's store, nil if none was made (or its password is gone, which leaves it unusable:
    /// Settings' Start Over removes it).
    static func current() -> Store? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .filter { $0.hasSuffix(".keychain-db") }.sorted() ?? []
        guard let name = files.last else { return nil }
        var item: CFTypeRef?
        guard SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: passwordService,
                                   kSecAttrAccount: name, kSecReturnData: true] as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let password = String(data: data, encoding: .utf8) else { return nil }
        return Store(path: folder.appending(path: name), password: password)
    }

    /// The companion's state: none, requested, or ready.
    static var state: State { current().map { (try? state(of: $0)) ?? .none } ?? .none }

    /// Makes the companion's store if there's none (a new keychain file, its password in the login
    /// keychain), then the key if it has none, and saves the request to `requestFile`. The same key gives the
    /// same request each time, so asking again is harmless.
    @discardableResult
    static func makeRequest() throws -> URL {
        let store: Store
        if let existing = current() {
            store = existing
        } else {
            let name = "slashplayed-\(UUID().uuidString).keychain-db"
            let password = try DeviceIdentity.newPassword()
            let st = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: passwordService, kSecAttrAccount: name,
                                 kSecAttrLabel: passwordService, kSecValueData: Data(password.utf8)] as CFDictionary, nil)
            guard st == errSecSuccess else { throw Failure("The keychain didn't keep the Slashplayed certificate keychain's password (\(st)).") }
            store = Store(path: folder.appending(path: name), password: password)
        }
        let pem = try request(store)
        try pem.write(to: requestFile, options: .atomic)
        return requestFile
    }

    /// Stop Using It's log line (Pipeline.stopUsingCertificate): "<device> deletes its copy" for one device,
    /// "<a> and <b> delete their copies" for more (one read "Paul's Apple Vision Pro delete their copies").
    static func deletedLine(sentTo: [String]) -> String {
        let deleted = "deleted the Slashplayed certificate and its key from this Mac"
        guard !sentTo.isEmpty else { return deleted }
        let deletes = sentTo.count == 1 ? "deletes its copy at its" : "delete their copies at their"
        return "\(deleted); \(SetupStatus.list(sentTo)) \(deletes) next Play or Update Client"
    }

    /// Deletes the companion's store: the key, the certificate, the keychain file, and its password.
    static func remove() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let path = folder.appending(path: name)
            var keychain: SecKeychain?
            if name.hasSuffix(".keychain-db"), SecKeychainOpen(path.path, &keychain) == errSecSuccess, let keychain {
                SecKeychainDelete(keychain)
            }
            try? FileManager.default.removeItem(at: path)
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: passwordService, kSecAttrAccount: name] as CFDictionary)
        }
        try? FileManager.default.removeItem(at: requestFile)
    }

    // MARK: A store

    /// Runs `body` with the store's keychain open and unlocked (made first if `create` and it isn't there),
    /// macOS's prompts off, and locks it again after.
    static func withKeychain<T>(_ store: Store, create: Bool = false, _ body: (SecKeychain) throws -> T) throws -> T {
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        var keychain: SecKeychain?
        if FileManager.default.fileExists(atPath: store.path.path) {
            guard SecKeychainOpen(store.path.path, &keychain) == errSecSuccess, let keychain,
                  SecKeychainUnlock(keychain, UInt32(store.password.utf8.count), store.password, true) == errSecSuccess else {
                throw Failure("The Slashplayed certificate's keychain (\(store.path.lastPathComponent)) couldn't be opened. Start over in Settings > Updates on Devices.")
            }
        } else {
            guard create else { throw Failure("The Slashplayed certificate's keychain isn't there any more.") }
            let st = SecKeychainCreate(store.path.path, UInt32(store.password.utf8.count), store.password, false, nil, &keychain)
            guard st == errSecSuccess, let keychain else { throw Failure("The Slashplayed certificate's keychain couldn't be made (\(st)).") }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.path.path)
            // Locks itself after 5 minutes unused and on sleep, should a lock below ever be missed.
            var settings = SecKeychainSettings(version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1), lockOnSleep: true,
                                               useLockInterval: true, lockInterval: 300)
            SecKeychainSetSettings(keychain, &settings)
            try keepOffSearchList(keychain)
        }
        let open = keychain!
        defer { SecKeychainLock(open) }
        return try body(open)
    }

    /// Takes the keychain off the user's search list, if anything put it there: that list is where Xcode and
    /// codesign look for identities.
    static func keepOffSearchList(_ keychain: SecKeychain) throws {
        var list: CFArray?
        guard SecKeychainCopySearchList(&list) == errSecSuccess, let list = list as? [SecKeychain] else { return }
        let ours = path(keychain)
        let rest = list.filter { path($0) != ours }
        if rest.count != list.count { SecKeychainSetSearchList(rest as CFArray) }
    }

    static func path(_ keychain: SecKeychain) -> String {
        var length: UInt32 = 1024
        var buffer = [CChar](repeating: 0, count: 1024)
        guard SecKeychainGetPath(keychain, &length, &buffer) == errSecSuccess else { return "" }
        return String(cString: buffer)
    }

    /// The store's key and certificate, as State.
    static func state(of store: Store) throws -> State {
        guard FileManager.default.fileExists(atPath: store.path.path) else { return .none }
        return try withKeychain(store) { keychain in
            guard let key = privateKey(in: keychain) else { return .none }
            let cert = certificate(for: key, in: keychain)
            guard usable(key) else { return .otherCopy(cert.map(describe)) }
            guard let cert else { return .requested }
            return .ready(describe(cert))
        }
    }

    /// Whether this copy of the companion may use the key: a test signature, which withKeychain's prompts-off
    /// makes macOS refuse at once when the key's access list names another copy (`.otherCopy`). Any other
    /// failure isn't that, and is left for the use itself to report.
    static func usable(_ key: SecKey) -> Bool {
        var error: Unmanaged<CFError>?
        if SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(count: 32) as CFData, &error) != nil { return true }
        let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
        return !DeviceIdentity.refusals.contains(OSStatus(code))
    }

    /// The certificate request for the store's key (made now if it has none), as PEM.
    static func request(_ store: Store) throws -> Data {
        try withKeychain(store, create: true) { keychain in
            let key = try privateKey(in: keychain) ?? makeKey(in: keychain)
            guard usable(key) else { throw Failure(otherCopyFix) }
            return try CertificateRequest.pem(key: key, commonName: label)
        }
    }

    /// Checks a certificate the person downloaded (DER, as the portal gives it, or PEM) against the store's
    /// key and `team`, and keeps it beside the key.
    @discardableResult
    static func add(_ file: Data, team: String, to store: Store, now: Date = Date()) throws -> Certificate {
        guard let cert = certificate(from: file) else {
            throw Failure("That isn't a certificate. Download the certificate from developer.apple.com (a .cer file) and choose that.")
        }
        return try withKeychain(store) { keychain in
            guard let key = privateKey(in: keychain) else {
                throw Failure("There's no Slashplayed key to match a certificate to. Make a certificate request first.")
            }
            try check(cert, key: key, team: team, now: now)
            let st = SecItemAdd([kSecValueRef: cert, kSecUseKeychain: keychain] as CFDictionary, nil)
            guard st == errSecSuccess || st == errSecDuplicateItem else {
                throw Failure("The certificate couldn't be kept in Slashplayed's keychain (\(st)).")
            }
            return describe(cert)
        }
    }

    /// The store's certificate, for its standing (DeviceIdentity.standing). Nil until it's ready.
    static func certificate(in store: Store) -> SecCertificate? {
        try? withKeychain(store) { keychain in privateKey(in: keychain).flatMap { certificate(for: $0, in: keychain) } }
    }

    /// The certificate in the companion's store.
    static func add(_ file: Data, team: String) throws -> Certificate {
        guard let store = current() else {
            throw Failure("There's no Slashplayed key to match a certificate to. Make a certificate request first.")
        }
        return try add(file, team: team, to: store)
    }

    /// The certificate is for this key, of this team (its subject's organizational unit, as Apple names
    /// development certificates), and valid now.
    static func check(_ cert: SecCertificate, key: SecKey, team: String, now: Date = Date()) throws {
        guard let certKey = SecCertificateCopyKey(cert), let pub = SecKeyCopyPublicKey(key),
              let a = SecKeyCopyExternalRepresentation(certKey, nil) as Data?,
              let b = SecKeyCopyExternalRepresentation(pub, nil) as Data?, a == b else {
            throw Failure("That certificate wasn't made from Slashplayed's request. On developer.apple.com, make the certificate with the request Slashplayed saved (\(requestFile.lastPathComponent)), then choose the certificate you download.")
        }
        let units = organizationalUnits(cert)
        guard units.contains(team) else {
            throw Failure("That certificate is for team \(units.first ?? "unknown"), not \(team), the team Slashplayed signs with. Sign in to developer.apple.com with team \(team) and make the certificate there.")
        }
        if let start = SecCertificateCopyNotValidBeforeDate(cert) as Date?, start > now {
            throw Failure("That certificate isn't valid yet.")
        }
        if let end = SecCertificateCopyNotValidAfterDate(cert) as Date?, end <= now {
            throw Failure("That certificate has expired. Make a new one on developer.apple.com with Slashplayed's request.")
        }
    }

    /// The identity's .p12 under `password`, for a push: the store's certificate and key, which this app may
    /// export without asking.
    static func export(_ store: Store, hash: String, password: String) throws -> Data {
        try withKeychain(store) { try DeviceIdentity.export(hash: hash, password: password, keychains: [$0]) }
    }

    // MARK: Profiles

    /// Whether a provisioning profile (the CMS envelope, as a device installs it) lists the certificate with
    /// this SHA-1 among its DeveloperCertificates.
    static func lists(profile: Data, hash: String) -> Bool {
        let certs = Signing.profilePlist(profile)?["DeveloperCertificates"] as? [Data] ?? []
        return certs.contains { DeviceIdentity.sha1($0) == hash.uppercased() }
    }

    // MARK: Keys and certificates

    static func privateKey(in keychain: SecKeychain) -> SecKey? {
        var found: CFTypeRef?
        guard SecItemCopyMatching([kSecClass: kSecClassKey, kSecAttrKeyClass: kSecAttrKeyClassPrivate, kSecAttrLabel: label,
                                   kSecMatchSearchList: [keychain], kSecReturnRef: true] as CFDictionary, &found) == errSecSuccess
        else { return nil }
        return (found as! SecKey)
    }

    static func makeKey(in keychain: SecKeychain) throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048, kSecUseKeychain: keychain,
            // Extractable, as the .p12 for a device needs.
            kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true, kSecAttrLabel: label, kSecAttrIsExtractable: true] as CFDictionary,
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw Failure("The Slashplayed key couldn't be made: \(error.map { $0.takeRetainedValue().localizedDescription } ?? "no reason given").")
        }
        return key
    }

    /// The keychain's certificate for `key` (the newest, if the person added more than one).
    static func certificate(for key: SecKey, in keychain: SecKeychain) -> SecCertificate? {
        var found: CFTypeRef?
        guard SecItemCopyMatching([kSecClass: kSecClassCertificate, kSecMatchSearchList: [keychain], kSecReturnRef: true,
                                   kSecMatchLimit: kSecMatchLimitAll] as CFDictionary, &found) == errSecSuccess,
              let pub = SecKeyCopyPublicKey(key).flatMap({ SecKeyCopyExternalRepresentation($0, nil) as Data? }) else { return nil }
        return (found as? [SecCertificate] ?? [])
            .filter { SecCertificateCopyKey($0).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? } == pub }
            .max { (SecCertificateCopyNotValidAfterDate($0) as Date? ?? .distantPast) < (SecCertificateCopyNotValidAfterDate($1) as Date? ?? .distantPast) }
    }

    /// A .cer as the portal gives it (DER), or PEM.
    static func certificate(from file: Data) -> SecCertificate? {
        if let cert = SecCertificateCreateWithData(nil, file as CFData) { return cert }
        guard let text = String(data: file, encoding: .utf8),
              let body = text.firstMatch(of: /-----BEGIN CERTIFICATE-----([A-Za-z0-9+\/=\s]+)-----END CERTIFICATE-----/)?.1,
              let der = Data(base64Encoded: String(body).filter { !$0.isWhitespace }) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    static func describe(_ cert: SecCertificate) -> Certificate {
        let expires = SecCertificateCopyNotValidAfterDate(cert) as Date? ?? .distantPast
        return Certificate(hash: DeviceIdentity.sha1(SecCertificateCopyData(cert) as Data),
                           name: SecCertificateCopySubjectSummary(cert) as String? ?? label,
                           validUntil: DeviceIdentity.day(expires), expires: expires)
    }

    /// The subject's OU values (an Apple development certificate's is the team ID).
    static func organizationalUnits(_ cert: SecCertificate) -> [String] {
        guard let values = SecCertificateCopyValues(cert, [kSecOIDX509V1SubjectName] as CFArray, nil) as? [CFString: Any],
              let subject = values[kSecOIDX509V1SubjectName] as? [CFString: Any],
              let parts = subject[kSecPropertyKeyValue] as? [[CFString: Any]] else { return [] }
        return parts.filter { ($0[kSecPropertyKeyLabel] as? String) == (kSecOIDOrganizationalUnitName as String) }
            .compactMap { $0[kSecPropertyKeyValue] as? String }
    }
}

/// A PKCS#10 certificate signing request (RFC 2986) for an RSA key, as Keychain Access's Certificate
/// Assistant makes for developer.apple.com: the subject (a common name), the public key, no attributes,
/// signed with SHA-256.
enum CertificateRequest {
    static func der(key: SecKey, commonName: String) throws -> Data {
        guard let pub = SecKeyCopyPublicKey(key), let pkcs1 = SecKeyCopyExternalRepresentation(pub, nil) as Data? else {
            throw Failure("The Slashplayed key's public half couldn't be read.")
        }
        let rsaEncryption = DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])        // 1.2.840.113549.1.1.1
        let sha256WithRSA = DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B])        // 1.2.840.113549.1.1.11
        let commonNameOID = DER.oid([0x55, 0x04, 0x03])                                             // 2.5.4.3
        let subject = DER.sequence([DER.set([DER.sequence([commonNameOID, DER.utf8(commonName)])])])
        let publicKeyInfo = DER.sequence([DER.sequence([rsaEncryption, DER.null]), DER.bitString(pkcs1)])
        // version 0, subject, key, and an empty [0] attribute set.
        let info = DER.sequence([DER.integer(0), subject, publicKeyInfo, DER.tagged(0xA0, Data())])
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, info as CFData, &error) as Data? else {
            throw Failure("The certificate request couldn't be signed: \(error.map { $0.takeRetainedValue().localizedDescription } ?? "no reason given").")
        }
        return DER.sequence([info, DER.sequence([sha256WithRSA, DER.null]), DER.bitString(signature)])
    }

    static func pem(key: SecKey, commonName: String) throws -> Data {
        let base64 = try der(key: key, commonName: commonName).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN CERTIFICATE REQUEST-----\n\(base64)\n-----END CERTIFICATE REQUEST-----\n".utf8)
    }
}

/// Just enough DER to write a certificate request.
enum DER {
    static func tagged(_ tag: UInt8, _ body: Data) -> Data {
        var out = Data([tag])
        if body.count < 0x80 {
            out.append(UInt8(body.count))
        } else {
            var length = body.count, bytes: [UInt8] = []
            while length > 0 { bytes.insert(UInt8(length & 0xFF), at: 0); length >>= 8 }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        return out + body
    }

    static func sequence(_ items: [Data]) -> Data { tagged(0x30, items.reduce(Data(), +)) }
    static func set(_ items: [Data]) -> Data { tagged(0x31, items.reduce(Data(), +)) }
    static func oid(_ encoded: [UInt8]) -> Data { tagged(0x06, Data(encoded)) }
    static func utf8(_ s: String) -> Data { tagged(0x0C, Data(s.utf8)) }
    static func bitString(_ bytes: Data) -> Data { tagged(0x03, Data([0]) + bytes) }
    static func integer(_ value: UInt8) -> Data { tagged(0x02, Data([value])) }
    static let null = Data([0x05, 0x00])
}
