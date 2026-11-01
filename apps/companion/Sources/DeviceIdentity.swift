import CryptoKit
import Foundation
import Security

/// The signing identity a device needs to update a game by itself: with it, the launcher signs the new
/// client image it assembles (apps/client/spsign.m), and the image loads from Library/ because an installed
/// profile lists the certificate (research/dlopentest). It comes from this Mac, only for a device whose
/// Update Games on This Device is on (off for every device until the person turns it on, after reading what
/// it sends), and goes into Slashplayed's keychain on that device alone (this device only, never synced).
///
/// Where the key comes from depends on the team. A free team uses **A**: the identity the companion already
/// signs the app with (Signing.provision's), exported from the login keychain as a .p12 here, with
/// macOS's own export prompt as the consent. A paid team uses **B**: a certificate of Slashplayed's own,
/// made for this and kept out of Xcode's reach (SlashplayedCertificate; until it's set up, a paid team gets
/// nothing), which the companion exports without asking. The `signingSource` default (A or B) overrides
/// the team's choice, so a paid team can test A.
///
/// The identity is a credential: the .p12 and its password are never logged, printed, or kept. Each push
/// has a new random password; both files are written 0600 into a 0700 folder, copied to the device as
/// Library/spidentity.p12 and spidentity.pass (the launcher imports and deletes them at its next start), and
/// zeroed and deleted here at once, as Pairing does with the pairing record. Logs give sizes only, and the
/// identity's name at most, never its SHA-1.
enum DeviceIdentity {
    enum Source: String { case a = "A", b = "B" }

    /// UserDefaults key of the test override: "A" or "B" (anything else, or unset: the team decides).
    static let sourceOverrideKey = "signingSource"

    /// A for a free team, B for a paid one, unless `override` names one.
    static func source(teamIsFree: Bool, override: String?) -> Source {
        override.flatMap(Source.init) ?? (teamIsFree ? .a : .b)
    }

    /// The chosen team's source (Signing.teamKey). Nil while no team is chosen or its account isn't
    /// signed in to Xcode.
    static var source: Source? {
        guard let id = UserDefaults.standard.string(forKey: Signing.teamKey),
              let team = Signing.teams().first(where: { $0.id == id }) else { return nil }
        return source(teamIsFree: team.isFree, override: UserDefaults.standard.string(forKey: sourceOverrideKey))
    }

    // MARK: On the device

    /// Where the launcher takes them from, and deletes them (spsign.m).
    static let p12Path = "Library/spidentity.p12"
    static let passwordPath = "Library/spidentity.pass"
    /// Asks the launcher to delete the identity at its next start: Update Games on This Device turned off.
    static let forgetPath = "Library/spidentity.forget"
    /// What the launcher found at its last start (sp_identity_describe), for the decision.
    static let statusPath = "Library/spidentity.txt"
    /// A copy of the profile the companion installed for the Slashplayed certificate (B), so the launcher knows
    /// a profile lists it (sp_listed_certificates): it can read its own embedded.mobileprovision, not the
    /// device's list of installed profiles.
    static let profilePath = "Library/spprofile.mobileprovision"

    /// Library/spidentity.txt: whether the device's keychain holds an identity, and its certificate's last
    /// valid day (UTC, yyyy-MM-dd), which is how the companion tells its own identity from another one
    /// without the device ever naming it.
    struct Status: Equatable {
        enum State: String { case present, expired, none, forgotten, unreadable }
        let state: State
        let validUntil: String?

        init(state: State, validUntil: String? = nil) {
            self.state = state
            self.validUntil = validUntil
        }

        /// "present 2027-10-24", "expired 2026-01-02", "none", "forgotten", "unreadable"; nil for anything else.
        init?(_ text: String) {
            let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = words.first, let state = State(rawValue: first) else { return nil }
            let day = words.count > 1 && words[1].wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil ? words[1] : nil
            guard (state == .present || state == .expired) == (day != nil) else { return nil }
            self.init(state: state, validUntil: day)
        }
    }

    /// A certificate's last valid day as the launcher writes it.
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: The decision

    enum Decision: Equatable {
        /// Nothing to send; why, for the log.
        case nothing(String)
        /// Send the identity; why.
        case push(String)
        /// Send the forget marker: the setting was turned off after a push.
        case forget
        /// The person forgot what was sent in the device's Settings: turn the setting off rather than push it
        /// back (and forget the record, so turning it on again sends it).
        case turnOff
    }

    /// Whether to push the identity to a device.
    /// - on: its Update Games on This Device.
    /// - source: the team's (or the override's).
    /// - identity: the SHA-1 of the identity to send, and its certificate's last valid day (`day`): for A the
    ///   built app's signer (nil when there's no build yet), for B the Slashplayed certificate (nil until
    ///   it's set up, or once it has expired).
    /// - pushed: the SHA-1 last pushed to the device (pushedKey), nil if none since the setting was last off.
    /// - pushedSource: the source that SHA-1 came from (pushedSource(recorded:pushed:certificate:)), for the
    ///   log's reason when it isn't the identity to send now.
    /// - status: the device's Library/spidentity.txt, nil if it has none (no launcher start since this
    ///   version) or it didn't parse.
    /// - pending: a pushed .p12 is still waiting on the device for the launcher's next start.
    static func decide(on: Bool, source: Source, identity: (hash: String, validUntil: String)?, pushed: String?,
                       pushedSource: Source?, status: Status?, pending: Bool) -> Decision {
        guard on else { return pushed != nil ? .forget : .nothing("Update Games on This Device is off") }
        // The device keeps saying so until its next import, so only a Forget of what was sent counts: with no
        // record (cleared at the turn-off), the setting was turned on again since, and it's sent.
        if status?.state == .forgotten && pushed != nil { return .turnOff }
        guard let identity else {
            return .nothing(source == .a ? "there's no build yet to take the signing identity from"
                                         : "a paid team signs device updates with a Slashplayed certificate of its own, which isn't set up (Settings > Updates on Devices)")
        }
        if pending && pushed == identity.hash { return .nothing("the identity sent last is waiting for Slashplayed's next start on the device") }
        guard let status else { return .push("the device hasn't said whether it has one") }
        switch status.state {
        case .none: return .push("the device has none")
        case .forgotten: return .push("it was turned on again since the device forgot it")
        case .unreadable: return .push("the device's copy can't be read")
        case .expired: return .push("the device's copy has expired")
        case .present: break
        }
        if pushed != identity.hash { return .push(change(from: pushed.flatMap { _ in pushedSource }, to: source)) }
        if status.validUntil != identity.validUntil { return .push("the device holds another identity") }
        return .nothing("the device has the current identity")
    }

    /// Why the identity to send isn't the one sent last: the source switched (the `signingSource` override
    /// set or deleted, or the team changed kind), or the same source has another certificate now. `from` is
    /// nil when nothing was sent since the setting was last turned on, and the device holds one anyway.
    static func change(from pushed: Source?, to source: Source) -> String {
        switch (pushed, source) {
        case (.a, .a): "Xcode replaced the certificate Slashplayed signs with"
        case (.b, .b): "there's a new Slashplayed certificate"
        case (.a, .b): "the device gets the Slashplayed certificate (B) instead of the identity this Mac signs with (A)"
        case (.b, .a): "the device gets the identity this Mac signs with (A) instead of the Slashplayed certificate (B)"
        case (nil, _): "the device's identity wasn't sent from this Mac since Update Games on This Device was turned on"
        }
    }

    /// The source of the SHA-1 last pushed: the one recorded with it (pushedSourceKey), or, for a push from
    /// before that record existed, B if it's the Slashplayed certificate's SHA-1 and A otherwise (stopping the
    /// Slashplayed certificate turns the setting off on every device it went to, so a B push that's still on
    /// record is the current certificate's). Nil if nothing was pushed.
    static func pushedSource(recorded: String?, pushed: String?, certificate: String?) -> Source? {
        guard let pushed else { return nil }
        return recorded.flatMap(Source.init) ?? (pushed == certificate ? .b : .a)
    }

    // MARK: The export

    /// The identity with this certificate SHA-1 in `keychains` (nil: the user's search list, the login
    /// keychain), exported as a .p12 opened by `password`. macOS asks the person to allow the export (unless
    /// the key's access list already lets this app, as a test keychain's does); a refusal throws Refused.
    static func export(hash: String, password: String, keychains: [SecKeychain]? = nil) throws -> Data {
        var query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll]
        if let keychains { query[kSecMatchSearchList] = keychains }
        var found: CFTypeRef?
        let st = SecItemCopyMatching(query as CFDictionary, &found)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw Failure("The keychain couldn't be searched for the signing identity (\(st)).") }
        let identity = (found as? [SecIdentity] ?? []).first { id in
            var cert: SecCertificate?
            guard SecIdentityCopyCertificate(id, &cert) == errSecSuccess, let cert else { return false }
            return sha1(SecCertificateCopyData(cert) as Data) == hash.uppercased()
        }
        guard let identity else { throw Failure("The identity Slashplayed signs with isn't in this Mac's keychain any more. Press Play or Update Client to sign with the current one.") }
        var params = SecItemImportExportKeyParameters()
        params.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
        let passphrase = password as CFString
        params.passphrase = Unmanaged.passUnretained(passphrase)
        var data: CFData?
        let e = withExtendedLifetime(passphrase) { SecItemExport(identity, .formatPKCS12, [], &params, &data) }
        if refusals.contains(e) { throw Refused(status: e) }
        guard e == errSecSuccess, let data = data as Data?, !data.isEmpty else {
            throw Failure("The keychain couldn't export the signing identity (\(e)).")
        }
        return data
    }

    /// What the keychain answers when the person denies the export, or it can't ask: user canceled, auth
    /// failed, interaction not allowed.
    static let refusals: Set<OSStatus> = [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed]

    struct Refused: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "The keychain's export of the signing identity was refused (\(status))." }
    }

    /// The certificate's last valid day (`day`) for the identity with this SHA-1, from the login keychain's
    /// certificates (no private key is touched, so no prompt). Nil if it isn't there.
    static func validUntil(hash: String) -> String? {
        certificate(hash: hash).flatMap { SecCertificateCopyNotValidAfterDate($0) as Date? }.map(day)
    }

    /// The login keychain's certificate with this SHA-1, nil if it isn't there.
    static func certificate(hash: String) -> SecCertificate? {
        var found: CFTypeRef?
        guard SecItemCopyMatching([kSecClass: kSecClassCertificate, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll] as CFDictionary,
                                  &found) == errSecSuccess else { return nil }
        return (found as? [SecCertificate] ?? []).first { sha1(SecCertificateCopyData($0) as Data) == hash.uppercased() }
    }

    // MARK: The certificate's standing

    /// Whether Apple still stands behind a certificate a device signs with.
    enum Standing: Equatable {
        case good
        /// Its last valid day has passed.
        case expired(String)
        /// Revoked on developer.apple.com (Apple's OCSP responder says so).
        case revoked
        /// Apple couldn't be asked (offline, say), or its answer couldn't be checked: nothing is said then.
        case unknown(String)
    }

    /// The certificate's standing: its expiry, and whether it was revoked, from Apple's OCSP responder (the
    /// address the certificate names). macOS's own trust evaluation doesn't tell: SecTrust with a revocation
    /// policy (OCSP, a positive response required) and `security verify-cert -R ocsp -R require` both still
    /// called a development certificate trusted hours after it was revoked, while the responder said revoked
    /// (2026-10-24). So the responder is asked with /usr/bin/openssl ocsp, and its answer is taken only when
    /// its signature verifies against the chain SecTrust builds (the WWDR intermediate and Apple's root).
    /// Only public certificates are written, into a scratch folder deleted after.
    static func standing(of cert: SecCertificate, now: Date = Date()) async -> Standing {
        if let end = SecCertificateCopyNotValidAfterDate(cert) as Date?, end <= now { return .expired(day(end)) }
        let chain = await Task.detached { () -> [SecCertificate] in
            var trust: SecTrust?
            guard SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust else { return [] }
            SecTrustSetNetworkFetchAllowed(trust, true)
            _ = SecTrustEvaluateWithError(trust, nil)
            return SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        }.value
        guard chain.count >= 2 else { return .unknown("its issuer isn't known to this Mac") }
        let dir = FileManager.default.temporaryDirectory.appending(path: "spstanding-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let leaf = dir.appending(path: "leaf.pem"), issuer = dir.appending(path: "issuer.pem"), anchors = dir.appending(path: "chain.pem")
            try pem([chain[0]]).write(to: leaf)
            try pem([chain[1]]).write(to: issuer)
            try pem(Array(chain.dropFirst())).write(to: anchors)
            let uri = try await Shell.run("/usr/bin/openssl", ["x509", "-noout", "-ocsp_uri", "-in", leaf.path])
            guard let url = String(decoding: uri.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init),
                  url.hasPrefix("http") else { return .unknown("it names no OCSP responder") }
            let answer = try await Shell.run("/usr/bin/openssl", ["ocsp", "-issuer", issuer.path, "-cert", leaf.path, "-url", url,
                                                                  "-CAfile", anchors.path, "-timeout", "10"], check: false)
            return ocspStanding(String(decoding: answer.stdout, as: UTF8.self) + answer.stderr, certFile: leaf.path)
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// openssl ocsp's answer for `certFile`: good or revoked only when the response verified.
    static func ocspStanding(_ output: String, certFile: String) -> Standing {
        guard output.contains("Response verify OK") else { return .unknown("Apple's answer couldn't be checked") }
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix(certFile + ": ") {
            switch line.dropFirst(certFile.count + 2).trimmingCharacters(in: .whitespaces) {
            case "good": return .good
            case "revoked": return .revoked
            case let other: return .unknown("Apple's answer was \(other)")
            }
        }
        return .unknown("Apple gave no answer for it")
    }

    static func pem(_ certs: [SecCertificate]) -> Data {
        Data(certs.map { cert in
            let base64 = (SecCertificateCopyData(cert) as Data).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
        }.joined().utf8)
    }

    static func sha1(_ data: Data) -> String { Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined() }

    /// A new password for each push: 32 random bytes, base64.
    static func newPassword() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure("No random bytes for the identity's password.") }
        defer { bytes.withUnsafeMutableBytes { _ = memset($0.baseAddress!, 0, $0.count) } }
        return Data(bytes).base64EncodedString()
    }

    // MARK: Pushing

    /// UserDefaults key of the SHA-1 last pushed to the device (the companion's own record, kept on this
    /// Mac), cleared once the forget marker is sent.
    static func pushedKey(_ device: Device) -> String { "identityPushed.\(device.udid)" }
    /// UserDefaults key of the source (A or B) that SHA-1 came from, set and cleared with it.
    static func pushedSourceKey(_ device: Device) -> String { "identityPushedSource.\(device.udid)" }

    /// The device's status file and whether a push waits there, read with devicectl.
    static func deviceState(_ device: Device) async throws -> (status: Status?, pending: Bool) {
        let library = try await device.files(in: "Library", recursive: false)
        let pending = (library[(p12Path as NSString).lastPathComponent]?.size ?? 0) > 0
        guard library[(statusPath as NSString).lastPathComponent] != nil else { return (nil, pending) }
        let dir = FileManager.default.temporaryDirectory.appending(path: "spidentity-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "spidentity.txt")
        try await device.fetch(statusPath, to: file)
        return ((try? String(contentsOf: file, encoding: .utf8)).flatMap(Status.init), pending)
    }

    /// Exports the identity with a new password (`export`: from the login keychain for A, from the
    /// Slashplayed certificate's keychain for B) and copies both into the device's Library/. Returns the
    /// sizes, for the log.
    static func push(hash: String, to device: Device,
                     export: @escaping @Sendable (_ hash: String, _ password: String) throws -> Data = { try DeviceIdentity.export(hash: $0, password: $1) })
        async throws -> (p12: Int, password: Int) {
        let password = try newPassword()
        let p12 = try await Task.detached { try export(hash, password) }.value
        let dir = FileManager.default.temporaryDirectory.appending(path: "spidentity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let p12File = dir.appending(path: "spidentity.p12"), passwordFile = dir.appending(path: "spidentity.pass")
        defer {
            overwrite(p12File)
            overwrite(passwordFile)
        }
        let passwordData = Data(password.utf8)
        guard FileManager.default.createFile(atPath: p12File.path, contents: p12, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: passwordFile.path, contents: passwordData, attributes: [.posixPermissions: 0o600]) else {
            throw Failure("Couldn't write the signing identity to \(dir.path).")
        }
        // The .p12 first: the launcher imports only a whole pair, and deletes a half one.
        try await device.copy(p12File, to: p12Path)
        try await device.copy(passwordFile, to: passwordPath)
        return (p12.count, passwordData.count)
    }

    /// Asks the device's launcher to delete the identity at its next start.
    static func sendForget(to device: Device) async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spidentity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "spidentity.forget")
        guard FileManager.default.createFile(atPath: file.path, contents: Data("forget\n".utf8)) else {
            throw Failure("Couldn't write the forget request to \(dir.path).")
        }
        try await device.copy(file, to: forgetPath)
    }

    /// Zeroes a file before it's deleted, as rm -P does.
    private static func overwrite(_ file: URL) {
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: Data(count: Int(size)))
        try? handle.synchronize()
    }
}

extension Device {
    /// Whether a new device updates its games itself: off, as anything that puts a credential on a device
    /// is the person's choice, made after reading what it sends.
    static let updatesGamesByDefault = false

    /// UserDefaults key of Update Games on This Device: a Bool, unset until it's turned on.
    var updateGamesKey: String { "updateGames.\(udid)" }

    var updatesGames: Bool { updatesGames(UserDefaults.standard) }

    func updatesGames(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: updateGamesKey) as? Bool ?? Self.updatesGamesByDefault
    }

    func setUpdatesGames(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: updateGamesKey)
    }
}
