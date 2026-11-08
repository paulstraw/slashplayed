import Foundation
import zlib

/// Which of the install's shared game store archives (Data/data/data.NNN) the given products use: the
/// Swift port of apps/client/casc_archives.py (keep the two in step; the Python stays for seed.sh).
///
/// Every flavor shares one store (~150 GB with every game). A device that can't hold it all only needs the
/// archives holding the blocks of its flavors' builds: every encoded key in a build's encoding file
/// (which lists all of the build's content), plus the encoding file itself, looked up in the local .idx
/// files. Only reads the install. Formats: https://wowdev.wiki/CASC (local .idx v7, encoding file, BLTE).
/// Free of the app's own types (Flavor, Device), so the tests build it alone.
enum GameStore {
    struct Usage {
        /// The archive numbers.
        var archives: Set<Int>
        /// Per product: the encoded keys found in the local indexes, of all its encoding file lists.
        var found: [String: (found: Int, total: Int)]
        /// The bytes of the blocks used, summed over products (a block two products share counts twice,
        /// as casc_archives.py counts it).
        var blockBytes: Int64
    }

    /// The archives `products` (.build.info's Product column: wow_classic_era, wow_anniversary, wow_classic, wow) use.
    static func archives(root: URL, products: [String]) throws -> Usage {
        let info = try buildInfo(root)
        let index = try readIndexes(root)
        var usage = Usage(archives: [], found: [:], blockBytes: 0)
        for product in products {
            guard let buildKey = info[product]?["Build Key"], !buildKey.isEmpty else {
                throw Failure("The game install's .build.info has no build for \(product).")
            }
            let build = try config(root, buildKey)
            guard let encodingKey = build["encoding"], encodingKey.count >= 2 else {
                throw Failure("\(product)'s build config names no encoding file.")
            }
            let (archive, encoding) = try readFile(root, index, hex: encodingKey[1])
            usage.archives.insert(archive)
            var total = 0, found = 0
            try forEachEncodedKey(encoding) { key in
                total += 1
                guard let hit = index[key] else { return }
                found += 1
                usage.archives.insert(hit.archive)
                usage.blockBytes += Int64(hit.size)
            }
            usage.found[product] = (found, total)
        }
        return usage
    }

    // MARK: Install files

    /// .build.info's rows by product (installTable's: one for every installed game).
    static func buildInfo(_ root: URL) throws -> [String: [String: String]] {
        try installTable(root).byProduct
    }

    /// The install's .build.info, with a row added for each installed game it doesn't list (installedRow).
    /// Battle.net's file doesn't always list every game in the install. On 2026-11-07 its agent's record of
    /// what's installed was reset (the old agent's log ends on a DELETE /agent; the new one's product.db
    /// names only the game installed next), and Forever's install then wrote a .build.info holding Forever's
    /// row alone, with Classic Era, Anniversary, MoP Classic, and Retail still installed beside it.
    static func installTable(_ root: URL) throws -> BuildInfo {
        guard var table = BuildInfo(try String(contentsOf: root.appending(path: ".build.info"), encoding: .utf8)) else {
            throw Failure("The game install's .build.info is empty.")
        }
        let listed = table.byProduct
        let missing = flavorFolders(root).filter { listed[$0.product] == nil }
        guard !missing.isEmpty else { return table }
        let configs = buildConfigs(root)
        for game in missing {
            guard let row = installedRow(root, game, configs: configs) else { continue }
            table.lines.append(table.columns.map { row[$0] ?? "" }.joined(separator: "|"))
        }
        return table
    }

    /// The install's game folders (_retail_ and the like) with the product each one's .flavor.info names:
    /// Battle.net writes it in every game's folder as a one-column table (Product Flavor).
    static func flavorFolders(_ root: URL) -> [(product: String, folder: String)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().filter { $0.count > 2 && $0.hasPrefix("_") && $0.hasSuffix("_") }.compactMap { folder in
            guard let text = try? String(contentsOf: root.appending(path: "\(folder)/.flavor.info"), encoding: .utf8),
                  let table = BuildInfo(text), let line = table.lines.first,
                  let product = table.row(line)["Product Flavor"], !product.isEmpty else { return nil }
            return (product, folder)
        }
    }

    /// The build configs in Data/config (config/ab/cd/<key>, the ones with a build-uid), by key.
    static func buildConfigs(_ root: URL) -> [String: [String: [String]]] {
        let dir = root.appending(path: "Data/config")
        let ls = { (url: URL) in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] }
        var out: [String: [String: [String]]] = [:]
        for a in ls(dir) { for b in ls(dir.appending(path: a)) { for key in ls(dir.appending(path: "\(a)/\(b)")) {
            guard let text = try? String(contentsOf: dir.appending(path: "\(a)/\(b)/\(key)"), encoding: .utf8) else { continue }
            let config = parseConfig(text)
            if config["build-uid"] != nil { out[key] = config }
        } } }
        return out
    }

    /// The game's row as far as the install says it without .build.info: its product, the build of its
    /// client (the app in its folder's CFBundleVersion, 12.1.5.70688, which is .build.info's Version), and the
    /// key of the build config for that build (build-uid the product, build-name WOW-70688patch12.1.5_Retail).
    /// That's what Battle.net's own row holds for those three columns (Forever's, 2026-11-07). Nothing in the
    /// install names a game's region or tags apart from its row, so those stay empty (Flavor's defaults).
    /// Nil when no build config is the client's build.
    static func installedRow(_ root: URL, _ game: (product: String, folder: String),
                             configs: [String: [String: [String]]]) -> [String: String]? {
        let dir = root.appending(path: game.folder)
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".app") }.sorted()
        for app in apps {
            guard let version = NSDictionary(contentsOf: dir.appending(path: "\(app)/Contents/Info.plist"))?["CFBundleVersion"] as? String,
                  let dot = version.lastIndex(of: ".") else { continue }
            let name = "-\(version[version.index(after: dot)...])patch\(version[..<dot])"
            if let key = configs.keys.sorted().first(where: { key in
                configs[key]!["build-uid"] == [game.product] && configs[key]!["build-name"]?.first?.contains(name) == true
            }) {
                return ["Product": game.product, "Build Key": key, "Version": version]
            }
        }
        return nil
    }

    /// A .build.info as text: the header line (column names with their !type suffixes) and the row lines,
    /// kept as they are so a table that isn't changed is written back byte for byte.
    struct BuildInfo {
        var header: String
        var lines: [String]
        var newline: String

        /// Nil for an empty file.
        init?(_ text: String) {
            newline = text.contains("\r\n") ? "\r\n" : "\n"
            let all = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            guard let first = all.first, !first.isEmpty else { return nil }
            header = first
            lines = all.dropFirst().filter { !$0.isEmpty }
        }

        var columns: [String] {
            header.split(separator: "|", omittingEmptySubsequences: false)
                .map { String($0.split(separator: "!", maxSplits: 1, omittingEmptySubsequences: false)[0]) }
        }

        func row(_ line: String) -> [String: String] {
            Dictionary(zip(columns, line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)),
                       uniquingKeysWith: { $1 })
        }

        /// The rows by product; a product's last row wins, as for the launcher and the build stamp.
        var byProduct: [String: [String: String]] {
            lines.reduce(into: [:]) { rows, line in
                let r = row(line)
                if let product = r["Product"] { rows[product] = r }
            }
        }

        var text: String { ([header] + lines).map { $0 + newline }.joined() }
    }

    /// .build.info's columns and their types, in Battle.net's order on the Mac.
    static let buildInfoColumns: [(name: String, type: String)] = [
        ("Branch", "STRING:0"), ("Active", "DEC:1"), ("Build Key", "HEX:16"), ("CDN Key", "HEX:16"),
        ("Install Key", "HEX:16"), ("IM Size", "DEC:4"), ("CDN Path", "STRING:0"), ("CDN Hosts", "STRING:0"),
        ("CDN Servers", "STRING:0"), ("Tags", "STRING:0"), ("Armadillo", "STRING:0"), ("Last Activated", "STRING:0"),
        ("Version", "STRING:0"), ("KeyRing", "HEX:16"), ("Product", "STRING:0"),
    ]

    /// A .build.info of these lines (BlizzardCDN.buildInfoLine), with Battle.net's header and newlines.
    static func buildInfoText(_ lines: [String]) -> String {
        ([buildInfoColumns.map { "\($0.name)!\($0.type)" }.joined(separator: "|")] + lines).map { $0 + "\n" }.joined()
    }

    /// Whether `a` is a later version than `b` (.build.info's Version: 1.15.9.70003, compared part by
    /// part as numbers). False when either isn't all numbers: a build that can't be told apart isn't
    /// called newer.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let parse = { (v: String) in v.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) } }
        let x = parse(a), y = parse(b)
        guard !x.isEmpty, !y.isEmpty, !x.contains(nil), !y.contains(nil) else { return false }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i]! : 0, q = i < y.count ? y[i]! : 0
            if p != q { return p > q }
        }
        return false
    }

    /// The .build.info the companion writes to a device: `mac` (the rows of the builds in its client
    /// images, BlizzardCDN.buildInfoLine), except that a product whose build on the device is newer
    /// (`newer`; an on-device update put it there) keeps the device's row, and a product only the device
    /// has keeps its row too. With neither, `mac` unchanged. A device row is laid out by `mac`'s columns,
    /// by name.
    static func deviceBuildInfo(mac: String, device: String?) -> (text: String, newer: [String]) {
        guard let macTable = BuildInfo(mac), let device, let deviceTable = BuildInfo(device) else { return (mac, []) }
        let macRows = macTable.byProduct, deviceRows = deviceTable.byProduct
        let newer = deviceRows.keys.sorted().filter { p in
            guard let mine = macRows[p]?["Version"], let theirs = deviceRows[p]?["Version"] else { return false }
            return isVersion(theirs, newerThan: mine)
        }
        let deviceOnly = deviceTable.lines.compactMap { deviceTable.row($0)["Product"] }
            .reduce(into: [String]()) { if macRows[$1] == nil, !$0.contains($1) { $0.append($1) } }
        guard !newer.isEmpty || !deviceOnly.isEmpty else { return (mac, []) }
        let columns = macTable.columns
        let laidOut = { (p: String) in columns.map { deviceRows[p]![$0] ?? "" }.joined(separator: "|") }
        var out = macTable, placed: Set<String> = []
        out.lines = macTable.lines.compactMap { line in
            guard let p = macTable.row(line)["Product"], newer.contains(p) else { return line }
            return placed.insert(p).inserted ? laidOut(p) : nil
        } + deviceOnly.map(laidOut)
        return (out.text, newer)
    }

    /// The device's local index files (paths like data/0a00000013.idx, relative to Data/) that a copy of
    /// the Mac's store wouldn't replace and that outrank the Mac's: a version above every one the Mac has
    /// for the bucket (the same folder and the name's first two hex digits). The client reads the newest
    /// index of each bucket, so after the Mac's archives were copied under such an index it would point
    /// into data that's no longer there. `device` is only the indexes the device's own client wrote
    /// (newer than its .build.info), which are never deleted.
    static func outranking(device: [String], mac: [String]) -> [String] {
        func parse(_ path: String) -> (bucket: String, version: Int)? {
            let name = (path as NSString).lastPathComponent
            guard name.count == 14, name.hasSuffix(".idx"), let v = Int(name.dropFirst(2).prefix(8), radix: 16) else { return nil }
            return ((path as NSString).deletingLastPathComponent + "/" + name.prefix(2), v)
        }
        var newest: [String: Int] = [:]
        for p in mac.compactMap(parse) { newest[p.bucket] = max(newest[p.bucket] ?? -1, p.version) }
        return device.filter { path in
            guard let p = parse(path) else { return false }
            return p.version > (newest[p.bucket] ?? -1)
        }
    }

    /// A config file (Data/config/ab/cd/abcd…): "key = value value…" lines.
    static func config(_ root: URL, _ key: String) throws -> [String: [String]] {
        guard key.count > 4 else { throw Failure("Bad config key \(key) in the game install.") }
        let url = root.appending(path: "Data/config/\(key.prefix(2))/\(key.dropFirst(2).prefix(2))/\(key)")
        return parseConfig(try String(contentsOf: url, encoding: .utf8))
    }

    /// A config's text as its keys' values (BlizzardCDN reads the CDN's copies with this too).
    static func parseConfig(_ text: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.range(of: " = ") else { continue }
            let k = line[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
            out[k] = line[eq.upperBound...].split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return out
    }

    /// The first 9 bytes of an encoded key, which is all a local index stores.
    struct KeyPrefix: Hashable {
        var high: UInt64
        var low: UInt8

        init<C: Collection<UInt8>>(_ bytes: C) {
            var it = bytes.makeIterator()
            high = 0
            for _ in 0..<8 { high = high << 8 | UInt64(it.next() ?? 0) }
            low = it.next() ?? 0
        }
    }

    struct Location {
        var archive: Int
        var offset: Int
        var size: UInt32
    }

    /// Key prefix → where its block is, from the newest .idx of each bucket (file names are 2 hex digits
    /// of bucket then 8 of version, e.g. 0a00000012.idx).
    static func readIndexes(_ root: URL) throws -> [KeyPrefix: Location] {
        let dir = root.appending(path: "Data/data")
        var newest: [Int: (version: Int, name: String)] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".idx") && name.count == 14 {
            guard let bucket = Int(name.prefix(2), radix: 16), let version = Int(name.dropFirst(2).prefix(8), radix: 16) else { continue }
            if let have = newest[bucket], have.version >= version { continue }
            newest[bucket] = (version, name)
        }
        var index: [KeyPrefix: Location] = [:]
        for name in newest.values.map(\.name) {
            let b = try Data(contentsOf: dir.appending(path: name))
            try b.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let p = raw.bindMemory(to: UInt8.self)
                guard p.count >= 0x28, le16(p, 8) == 7, p[12] == 4, p[13] == 5, p[14] == 9, p[15] == 30 else {
                    throw Failure("\(name) in the game install isn't a local index this version of Slashplayed reads.")
                }
                let n = Int(le32(p, 0x20))
                guard 0x28 + n <= p.count else { throw Failure("\(name) in the game install is cut short.") }
                index.reserveCapacity(index.count + n / 18)
                for q in stride(from: 0x28, to: 0x28 + n - 17, by: 18) {
                    var location: UInt64 = 0
                    for i in 0..<5 { location = location << 8 | UInt64(p[q + 9 + i]) }
                    index[KeyPrefix(p[q..<(q + 9)])] = Location(archive: Int(location >> 30),
                                                               offset: Int(location & ((1 << 30) - 1)),
                                                               size: le32(p, q + 14))
                }
            }
        }
        return index
    }

    /// The decoded file with encoded key `hex`, and the archive it's in.
    static func readFile(_ root: URL, _ index: [KeyPrefix: Location], hex: String) throws -> (archive: Int, data: Data) {
        guard let key = bytes(hex: hex), key.count >= 9, let at = index[KeyPrefix(key)] else {
            throw Failure("The game install's indexes don't have \(hex).")
        }
        let url = root.appending(path: String(format: "Data/data/data.%03d", at.archive))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(at.offset))
        let raw = try handle.read(upToCount: Int(at.size)) ?? Data()
        guard raw.count == Int(at.size), raw.count > 30 else { throw Failure("\(url.lastPathComponent) is shorter than its index says.") }
        return (at.archive, try blte(raw.dropFirst(30)))  // a 30-byte local header before the BLTE data
    }

    // MARK: Formats

    /// Decodes BLTE: a header, then chunks that are plain (N) or zlib (Z).
    static func blte(_ input: Data) throws -> Data {
        let data = Data(input)  // zero-based
        guard data.count >= 8, data.prefix(4) == Data("BLTE".utf8) else { throw Failure("A game file isn't BLTE-encoded.") }
        let headerSize = Int(be32(data, 4))
        var sizes: [Int]
        var p: Int
        if headerSize == 0 {
            sizes = [data.count - 8]
            p = 8
        } else {
            guard data.count >= 12 else { throw Failure("A BLTE header is cut short.") }
            let count = Int(data[9]) << 16 | Int(data[10]) << 8 | Int(data[11])  // after a flags byte
            guard data.count >= 12 + count * 24 else { throw Failure("A BLTE chunk table is cut short.") }
            sizes = (0..<count).map { Int(be32(data, 12 + $0 * 24)) }
            p = headerSize
        }
        var out = Data()
        for size in sizes {
            guard size > 0, p + size <= data.count else { throw Failure("A BLTE chunk runs past its file.") }
            let chunk = data[p..<(p + size)]
            p += size
            switch chunk.first {
            case UInt8(ascii: "N"): out.append(chunk.dropFirst())
            case UInt8(ascii: "Z"): out.append(try inflate(chunk.dropFirst()))
            default: throw Failure("A BLTE chunk has mode \(chunk.first.map { String(UnicodeScalar($0)) } ?? "?"), which Slashplayed doesn't read.")
            }
        }
        return out
    }

    /// Calls `body` with the 9-byte prefix of every encoded key in an encoding file's content-key pages.
    static func forEachEncodedKey(_ encoding: Data, _ body: (KeyPrefix) throws -> Void) throws {
        let enc = Data(encoding)
        guard enc.count >= 22, enc[0] == UInt8(ascii: "E"), enc[1] == UInt8(ascii: "N") else {
            throw Failure("The build's encoding file isn't one Slashplayed reads.")
        }
        let ckeyLen = Int(enc[3]), ekeyLen = Int(enc[4])
        let pageSize = (Int(enc[5]) << 8 | Int(enc[6])) * 1024
        let pages = Int(be32(enc, 9)), espec = Int(be32(enc, 18))
        let start = 22 + espec + pages * (ckeyLen + 16)
        guard ekeyLen >= 9, start + pages * pageSize <= enc.count else { throw Failure("The build's encoding file is cut short.") }
        try enc.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            for page in 0..<pages {
                var q = start + page * pageSize
                let end = q + pageSize
                while q < end {
                    let count = Int(b[q])
                    if count == 0 { break }
                    q += 1 + 5 + ckeyLen
                    for _ in 0..<count {
                        guard q + ekeyLen <= end else { throw Failure("The build's encoding file has a bad page.") }
                        try body(KeyPrefix(b[q..<(q + 9)]))
                        q += ekeyLen
                    }
                }
            }
        }
    }

    /// zlib-inflates `input` (with its zlib header), its decoded size unknown up front.
    static func inflate(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure("zlib failed to start.") }
        defer { inflateEnd(&stream) }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var input = Data(input)
        let status: Int32 = input.withUnsafeMutableBytes { (inBytes: UnsafeMutableRawBufferPointer) in
            stream.next_in = inBytes.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(inBytes.count)
            var status = Z_OK
            repeat {
                status = buffer.withUnsafeMutableBufferPointer { o in
                    stream.next_out = o.baseAddress
                    stream.avail_out = uInt(o.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                out.append(contentsOf: buffer[0..<(buffer.count - Int(stream.avail_out))])
            } while status == Z_OK
            return status
        }
        guard status == Z_STREAM_END else { throw Failure("A zlib chunk in the game store didn't decode (zlib \(status)).") }
        return out
    }

    private static func bytes(hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        return stride(from: 0, to: chars.count, by: 2).map { Int(String(decoding: chars[$0..<($0 + 2)], as: UTF8.self), radix: 16) }
            .reduce(into: [UInt8]?([])) { acc, v in if let v { acc?.append(UInt8(v)) } else { acc = nil } }
    }

    private static func be32(_ d: Data, _ o: Int) -> UInt32 {
        d[o..<(o + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func le16(_ p: UnsafeBufferPointer<UInt8>, _ o: Int) -> UInt16 { UInt16(p[o]) | UInt16(p[o + 1]) << 8 }

    private static func le32(_ p: UnsafeBufferPointer<UInt8>, _ o: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(p[o + $1]) << (8 * $1) }
    }
}

/// The small identity file login needs from the Mac (the device app reads <container>/Library/spidentity):
/// the Mac user's login name as getpwuid gives it, no terminator. The port of shims/ident/mac-identity.c,
/// whose output it matches byte for byte (the tests compare).
enum MacIdentity {
    static func contents() throws -> Data {
        guard let pw = getpwuid(getuid()), let name = pw.pointee.pw_name, name.pointee != 0 else {
            throw Failure("macOS didn't give this account's user name.")
        }
        return Data(bytes: name, count: strlen(name))
    }
}
