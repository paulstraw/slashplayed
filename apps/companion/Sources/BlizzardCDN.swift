import CryptoKit
import Foundation

/// Blizzard's patch service and CDN, for what the companion needs from them to make a client image
/// without the game installed on the Mac: a product's version row, the build's configs, and the arm64
/// slice of its Mac client. The Swift port of the untethered-updates research's tact.py and fetch_app.py
/// (scratch tools, not in the repo). Formats: https://wowdev.wiki/TACT.
///
/// Only the executable's arm64 slice is downloaded, not the universal file: the CDN keeps the executable
/// as a BLTE file of independently decodable chunks and honors HTTP ranges, so one ranged request fetches
/// just the chunks covering the slice (Classic Era: 51 MB of 93). The result is byte-identical to
/// `lipo -thin arm64` of the installed executable, so ClientAssembly's later steps don't change. The
/// encoding file (Retail's is 188 MB) is read the same way: its header, its page index, and the one page
/// that can hold the key.
///
/// Everything is checked against the key that names it, so the chain is as trustworthy as the version
/// row (HTTPS): a config's MD5 is its key, a chunked BLTE file's header's MD5 is its encoded key and that
/// header holds each chunk's MD5, an encoding page's MD5 is in the encoding file's page index, and the
/// install manifest's decoded MD5 is the content key the build config gives it.
///
/// Downloads are cached in `cache`, each file named for the key it came from (<key> or <key>.<part>), and
/// a product's keys-<product> lists what its current build uses; once a build is resolved, files no
/// product's current build uses are deleted. URLSession only, HTTPS only (no ATS exception).
/// Free of the app's own types (Paths, Device, Flavor), so the tests build it alone.
struct BlizzardCDN {
    /// One HTTP GET: the body, or with a range those bytes of it (a range past the end gives fewer).
    /// Throws NotFound for a 404.
    typealias Fetch = @Sendable (URL, Range<Int>?) async throws -> Data

    struct NotFound: Error { var url: URL }

    /// Where downloads are kept (the app's is Paths.cdn).
    var cache: URL
    var fetch: Fetch = BlizzardCDN.session
    /// The patch service's base URL for a region, as the launcher's (apps/client/sppatch.m).
    var patchService: @Sendable (String) -> URL = { URL(string: "https://\($0).version.battle.net/v2/products")! }
    /// The CDN's base URLs, tried in order: `connected` fills them in from the patch service.
    var servers: [URL] = []
    /// The region's row in the patch service's cdns table, as `connected` read it: .build.info's CDN
    /// columns.
    var cdns: CDNs?
    /// A stored (N) chunk bigger than this is read in part when only part is needed (an encoding page out
    /// of Retail's 110 MB of them); smaller ones are fetched whole, so their MD5 can be checked.
    var partialChunkBytes = 1 << 20

    /// The first request for a BLTE file: enough for a header of 680 chunks (the executables have 400–470),
    /// so the header seldom needs a second.
    static let headerProbe = 16 * 1024

    static let session: Fetch = { url, range in
        var request = URLRequest(url: url, timeoutInterval: 30)
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw NotFound(url: url) }
        guard status == (range == nil ? 200 : 206) else {
            throw Failure("\(url.host() ?? "Blizzard's CDN") answered HTTP \(status) for \(url.lastPathComponent).")
        }
        return data
    }

    // MARK: The patch service

    /// A product's row in the patch service's versions table: the build a region is on now.
    struct Version: Equatable {
        var region: String
        /// .build.info's Build Key and CDN Key.
        var buildConfig: String, cdnConfig: String
        /// Retail's KeyRing (empty for the Classic games).
        var keyRing: String
        var buildID: String
        /// The display version, .build.info's Version (1.15.9.70003).
        var versionsName: String
        var productConfig: String
    }

    func version(product: String, region: String) async throws -> Version {
        let row = try await serviceRow(product: product, region: region, table: "versions", key: "Region")
        guard let build = row["BuildConfig"], Self.isKey(build), let cdn = row["CDNConfig"], Self.isKey(cdn),
              let name = row["VersionsName"], !name.isEmpty else {
            throw Failure("Blizzard's patch service has no current build of \(product) for \(region).")
        }
        return Version(region: region, buildConfig: build, cdnConfig: cdn, keyRing: row["KeyRing"] ?? "",
                       buildID: row["BuildId"] ?? "", versionsName: name, productConfig: row["ProductConfig"] ?? "")
    }

    /// A region's CDN as the patch service's cdns table gives it: .build.info's CDN Path, CDN Hosts, and
    /// CDN Servers, as they are.
    struct CDNs: Equatable {
        var path: String, hosts: String, servers: String
    }

    /// This, with `servers` set to the region's CDN servers from the patch service's cdns table (its
    /// HTTPS servers in the table's order, or its hosts over HTTPS if it lists none) and `cdns` to the row.
    func connected(product: String, region: String) async throws -> BlizzardCDN {
        let row = try await serviceRow(product: product, region: region, table: "cdns", key: "Name")
        guard let path = row["Path"], !path.isEmpty else { throw Failure("Blizzard's patch service lists no CDN for \(product) in \(region).") }
        let words = { (column: String) in (row[column] ?? "").split(separator: " ").map(String.init) }
        var hosts = words("Servers").compactMap(URLComponents.init(string:)).filter { $0.scheme == "https" }.compactMap(\.host)
        if hosts.isEmpty { hosts = words("Hosts") }
        var copy = self
        copy.cdns = CDNs(path: path, hosts: row["Hosts"] ?? "", servers: row["Servers"] ?? "")
        copy.servers = hosts.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .compactMap { URL(string: "https://\($0)/\(path)") }
        guard !copy.servers.isEmpty else { throw Failure("Blizzard's patch service lists no CDN for \(product) in \(region).") }
        return copy
    }

    private func serviceRow(product: String, region: String, table: String, key: String) async throws -> [String: String] {
        // Both go into the URL (the region into a host name), so only what Blizzard uses gets there.
        guard region.wholeMatch(of: #/[a-z]+/#) != nil, product.wholeMatch(of: #/[a-z0-9_]+/#) != nil else {
            throw Failure("\(product) in \(region) isn't a product and region Blizzard's patch service has.")
        }
        let text = String(decoding: try await fetch(patchService(region).appending(path: "\(product)/\(table)"), nil), as: UTF8.self)
        guard let row = Self.rows(text).first(where: { $0[key] == region }) else {
            throw Failure("Blizzard's patch service has no \(region) row in \(product)'s \(table).")
        }
        return row
    }

    /// .build.info's row for a build, as Battle.net writes it on the Mac (columns GameStore.buildInfoColumns):
    /// the version row's keys and version, the cdns row's columns, and `tags` (the platform, region, and
    /// locale the client fetches content for). The install's own columns (Install Key, IM Size, Armadillo,
    /// Last Activated) are empty there too. Laid out as a .build.info line.
    static func buildInfoLine(product: String, version: Version, cdns: CDNs, tags: String) -> String {
        let row = ["Branch": version.region, "Active": "1", "Build Key": version.buildConfig, "CDN Key": version.cdnConfig,
                   "CDN Path": cdns.path, "CDN Hosts": cdns.hosts, "CDN Servers": cdns.servers, "Tags": tags,
                   "Version": version.versionsName, "KeyRing": version.keyRing, "Product": product]
        return GameStore.buildInfoColumns.map { row[$0.name] ?? "" }.joined(separator: "|")
    }

    /// The patch service's tables are .build.info's shape plus "## seqn = …" lines.
    static func rows(_ text: String) -> [[String: String]] {
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }.joined(separator: "\n")
        guard let table = GameStore.BuildInfo(lines) else { return [] }
        return table.lines.map(table.row)
    }

    // MARK: A build's client

    /// What the companion takes from the CDN for a game: its current version row, the build config, and
    /// the arm64 slice of its client (in the cache, as <encoded key>.arm64).
    struct Client {
        var version: Version
        var buildConfig: [String: [String]]
        var slice: URL
    }

    /// The current build of `product` in `region` and its client's arm64 slice. `executable` is the
    /// client's path in its game's folder, as Flavor.clientPath gives it.
    func client(product: String, region: String, executable: String) async throws -> Client {
        let version = try await version(product: product, region: region)
        let cdn = try await connected(product: product, region: region)
        let (config, slice) = try await cdn.slice(product: product, region: region, buildConfig: version.buildConfig,
                                                  cdnConfig: version.cdnConfig, executable: executable)
        return Client(version: version, buildConfig: config, slice: slice)
    }

    /// The arm64 slice of `executable` in a given build (needs `servers`), and the build config. Records
    /// the build as the product's current one and prunes the cache.
    func slice(product: String, region: String, buildConfig: String, cdnConfig: String,
               executable: String) async throws -> (buildConfig: [String: [String]], slice: URL) {
        let config = try await self.config(buildConfig)
        guard let install = config["install"], install.count >= 2, let installSize = config["install-size"]?.first.flatMap(Int.init),
              let encoding = config["encoding"], encoding.count >= 2 else {
            throw Failure("Build \(buildConfig) on Blizzard's CDN has no install manifest or encoding file.")
        }
        let manifest = try await read(Blob(loose: install[1]), 0..<installSize, cache: true)
        guard Self.md5(manifest).hex == install[0] else { throw Failure("Build \(buildConfig)'s install manifest doesn't match its key.") }
        let ckey = try Self.executableKey(Self.installEntries(manifest), path: executable, region: region)
        let ekey = try await encodedKey(ckey, encoding: Blob(loose: encoding[1])).hex
        var keys = [buildConfig, cdnConfig, install[1], encoding[1], ekey]

        let output = cache.appending(path: "\(ekey).arm64")
        if !FileManager.default.fileExists(atPath: output.path) {
            var blob = Blob(loose: ekey)
            do {
                _ = try await header(blob)
            } catch is NotFound {
                // Not loose: in one of the CDN's archives.
                let archives = try await self.config(cdnConfig)["archives"] ?? []
                guard let found = try await archiveBlob(ekey, archives: archives) else {
                    throw Failure("Blizzard's CDN doesn't have \(executable) for build \(buildConfig) any more.")
                }
                blob = found.blob
                keys += found.searched
            }
            let size = try await decodedSize(blob)
            let head = try await read(blob, 0..<min(4096, size), cache: false)
            let data = try await read(blob, Self.arm64Slice(head, fileSize: size), cache: false)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try data.write(to: output, options: .atomic)
        }
        try keys.joined(separator: "\n").write(to: cache.appending(path: "keys-\(product)"), atomically: true, encoding: .utf8)
        try prune()
        return (config, output)
    }

    /// Deletes the cached files no product's current build uses. A file belongs to the key before the
    /// first dot in its name; each keys-<product> lists one product's.
    func prune() throws {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: cache.path)) ?? []
        let lists = names.filter { $0.hasPrefix("keys-") }
        let keep = Set(try lists.flatMap { try String(contentsOf: cache.appending(path: $0), encoding: .utf8).split(separator: "\n").map(String.init) })
        for name in names where !name.hasPrefix("keys-") {
            let key = String(name.prefix { $0 != "." })
            if !keep.contains(key) { try? fm.removeItem(at: cache.appending(path: name)) }
        }
    }

    // MARK: Files on the CDN

    /// A config (build or CDN config), its bytes checked against its key; Data/config/ on the device
    /// holds the same bytes.
    func configData(_ key: String) async throws -> Data {
        guard Self.isKey(key) else { throw Failure("\(key) isn't a config key.") }
        return try await cached(key) {
            let data = try await get(Self.path("config", key), nil)
            guard Self.md5(data).hex == key else { throw Failure("Config \(key) from Blizzard's CDN doesn't match its key.") }
            return data
        }
    }

    func config(_ key: String) async throws -> [String: [String]] {
        GameStore.parseConfig(String(decoding: try await configData(key), as: UTF8.self))
    }

    /// A BLTE-encoded file on the CDN: loose (data/…/<ekey>) or a stretch of an archive.
    struct Blob {
        var ekey: String
        var path: String
        var offset = 0
        /// Its encoded size, when an archive index gives it.
        var size: Int?

        init(loose ekey: String) { self.ekey = ekey; path = BlizzardCDN.path("data", ekey) }
        init(ekey: String, archive: String, offset: Int, size: Int) {
            self.ekey = ekey; path = BlizzardCDN.path("data", archive); self.offset = offset; self.size = size
        }
    }

    /// A chunked BLTE file's chunks: where each is in the file and in the decoded content, and its MD5.
    struct Chunk: Equatable {
        var encoded: Range<Int>, decoded: Range<Int>
        var md5: Data
    }

    /// The chunk table of a BLTE header (all of it); nil for an unchunked file (header size 0), whose
    /// one chunk is the rest of the file.
    static func chunks(_ header: Data) throws -> [Chunk]? {
        let h = Data(header)
        guard h.count >= 8, h.prefix(4) == Data("BLTE".utf8) else { throw Failure("A file from Blizzard's CDN isn't BLTE-encoded.") }
        let size = Int(be(h, 4, 4))
        if size == 0 { return nil }
        guard h.count >= 12 else { throw Failure("A BLTE header from Blizzard's CDN is cut short.") }
        let count = Int(be(h, 9, 3))
        guard size >= 12 + count * 24, h.count >= size else { throw Failure("A BLTE chunk table from Blizzard's CDN is cut short.") }
        var out: [Chunk] = []
        var encoded = size, decoded = 0
        for i in 0..<count {
            let e = Int(be(h, 12 + i * 24, 4)), d = Int(be(h, 16 + i * 24, 4))
            out.append(Chunk(encoded: encoded..<(encoded + e), decoded: decoded..<(decoded + d),
                             md5: h[(20 + i * 24)..<(36 + i * 24)]))
            encoded += e
            decoded += d
        }
        return out
    }

    /// A blob's BLTE header: all of it for a chunked file (its MD5 is the encoded key), the first 8 bytes
    /// for an unchunked one.
    func header(_ blob: Blob) async throws -> Data {
        try await cached("\(blob.ekey).header") {
            let probe = try await get(blob.path, blob.offset..<(blob.offset + min(blob.size ?? Self.headerProbe, Self.headerProbe)))
            guard probe.count >= 8, probe.prefix(4) == Data("BLTE".utf8) else {
                throw Failure("\(blob.ekey) from Blizzard's CDN isn't BLTE-encoded.")
            }
            let size = Int(Self.be(probe, 4, 4))
            if size == 0 { return Data(probe.prefix(8)) }
            let header = probe.count >= size ? Data(probe.prefix(size)) : try await get(blob.path, blob.offset..<(blob.offset + size))
            guard header.count == size, Self.md5(header).hex == blob.ekey else {
                throw Failure("\(blob.ekey) from Blizzard's CDN doesn't match its key.")
            }
            return header
        }
    }

    /// The size of a blob's decoded content.
    func decodedSize(_ blob: Blob) async throws -> Int {
        if let chunks = try Self.chunks(try await header(blob)) { return chunks.last?.decoded.upperBound ?? 0 }
        return try await whole(blob, cache: true).count
    }

    /// `range` of a blob's decoded content, fetching only the chunks it covers (as one ranged request),
    /// each checked against its MD5. With `cache`, the chunks are kept (<ekey>.<chunk>). A range inside one
    /// stored chunk bigger than partialChunkBytes is read alone and isn't checked: the caller checks it
    /// (an encoding page against the page index).
    func read(_ blob: Blob, _ range: Range<Int>, cache: Bool) async throws -> Data {
        guard let chunks = try Self.chunks(try await header(blob)) else {
            let content = try await whole(blob, cache: cache)
            guard range.upperBound <= content.count else { throw Failure("\(blob.ekey) from Blizzard's CDN is shorter than its build says.") }
            return content[range]
        }
        guard range.upperBound <= (chunks.last?.decoded.upperBound ?? 0) else {
            throw Failure("\(blob.ekey) from Blizzard's CDN is shorter than its build says.")
        }
        let hit = chunks.indices.filter { chunks[$0].decoded.overlaps(range) }
        guard let first = hit.first, let last = hit.last else { return Data() }

        let c = chunks[first]
        if first == last, c.encoded.count == c.decoded.count + 1, c.encoded.count > partialChunkBytes {
            let at = blob.offset + c.encoded.lowerBound
            if try await get(blob.path, at..<(at + 1)) == Data("N".utf8) {
                let from = at + 1 + range.lowerBound - c.decoded.lowerBound
                return try await self.cached(cache ? "\(blob.ekey).\(range.lowerBound)-\(range.upperBound)" : nil) {
                    let part = try await get(blob.path, from..<(from + range.count))
                    guard part.count == range.count else { throw Failure("\(blob.ekey) from Blizzard's CDN is cut short.") }
                    return part
                }
            }
        }

        let names = hit.map { "\(blob.ekey).\($0)" }
        var encoded: [Data]
        if cache, let kept = try? names.map({ try Data(contentsOf: self.cache.appending(path: $0)) }) {
            encoded = kept
        } else {
            let run = (blob.offset + c.encoded.lowerBound)..<(blob.offset + chunks[last].encoded.upperBound)
            let data = try await get(blob.path, run)
            guard data.count == run.count else { throw Failure("\(blob.ekey) from Blizzard's CDN is cut short.") }
            encoded = hit.map { i in
                let r = chunks[i].encoded
                return Data(data[(data.startIndex + r.lowerBound - c.encoded.lowerBound)..<(data.startIndex + r.upperBound - c.encoded.lowerBound)])
            }
            for (i, chunk) in zip(hit, encoded) where Self.md5(chunk) != chunks[i].md5 {
                throw Failure("\(blob.ekey) from Blizzard's CDN has a chunk that doesn't match its checksum.")
            }
            if cache {
                try FileManager.default.createDirectory(at: self.cache, withIntermediateDirectories: true)
                for (name, chunk) in zip(names, encoded) { try chunk.write(to: self.cache.appending(path: name), options: .atomic) }
            }
        }
        var out = Data()
        for (i, chunk) in zip(hit, encoded) {
            let decoded = try Self.decodeChunk(chunk)
            guard decoded.count == chunks[i].decoded.count else { throw Failure("\(blob.ekey) from Blizzard's CDN decoded to the wrong size.") }
            out.append(decoded)
        }
        let start = range.lowerBound - c.decoded.lowerBound
        return out[start..<(start + range.count)]
    }

    /// An unchunked blob, decoded (its whole encoded file's MD5 is its key).
    private func whole(_ blob: Blob, cache: Bool) async throws -> Data {
        let raw = try await cached(cache ? "\(blob.ekey).whole" : nil) {
            let data = try await get(blob.path, blob.size.map { blob.offset..<(blob.offset + $0) })
            guard Self.md5(data).hex == blob.ekey else { throw Failure("\(blob.ekey) from Blizzard's CDN doesn't match its key.") }
            return data
        }
        return try GameStore.blte(raw)
    }

    /// A chunk's content: stored (N) or zlib (Z). Encrypted (E) and frame (F) chunks aren't in anything
    /// the companion reads.
    static func decodeChunk(_ chunk: Data) throws -> Data {
        switch chunk.first {
        case UInt8(ascii: "N"): return Data(chunk.dropFirst())
        case UInt8(ascii: "Z"): return try GameStore.inflate(chunk.dropFirst())
        default: throw Failure("A BLTE chunk from Blizzard's CDN has mode \(chunk.first.map { String(UnicodeScalar($0)) } ?? "?"), which Slashplayed doesn't read.")
        }
    }

    // MARK: The build's manifests

    /// The encoded key of content key `ckey`, from the build's encoding file: its header, its content-key
    /// page index, and the one page whose first key is the last at or before `ckey`.
    func encodedKey(_ ckey: Data, encoding: Blob) async throws -> Data {
        let head = try await read(encoding, 0..<22, cache: true)
        guard head.prefix(2) == Data("EN".utf8) else { throw Failure("The build's encoding file on Blizzard's CDN isn't one Slashplayed reads.") }
        let ckeyLen = Int(head[head.startIndex + 3]), ekeyLen = Int(head[head.startIndex + 4])
        let pageSize = Int(Self.be(head, 5, 2)) * 1024, pages = Int(Self.be(head, 9, 4)), espec = Int(Self.be(head, 18, 4))
        guard ckeyLen == ckey.count, ekeyLen > 0, pageSize > 0, pages > 0 else {
            throw Failure("The build's encoding file on Blizzard's CDN isn't one Slashplayed reads.")
        }
        let entry = ckeyLen + 16, indexStart = 22 + espec
        let index = Data(try await read(encoding, indexStart..<(indexStart + pages * entry), cache: true))
        let firstKey = { (page: Int) in index[(page * entry)..<(page * entry + ckeyLen)] }
        // The number of pages whose first key is at or before ckey; the last of them holds it, if any does.
        var lo = 0, hi = pages
        while lo < hi {
            let mid = (lo + hi) / 2
            if ckey.lexicographicallyPrecedes(firstKey(mid)) { hi = mid } else { lo = mid + 1 }
        }
        let page = lo - 1
        let notFound = Failure("The build's encoding file on Blizzard's CDN doesn't list its client.")
        guard page >= 0 else { throw notFound }
        let pagesStart = indexStart + pages * entry
        let body = Data(try await read(encoding, (pagesStart + page * pageSize)..<(pagesStart + (page + 1) * pageSize), cache: true))
        guard Self.md5(body) == index[(page * entry + ckeyLen)..<((page + 1) * entry)] else {
            throw Failure("A page of the build's encoding file on Blizzard's CDN doesn't match its checksum.")
        }
        var q = 0
        while q + 6 + ckeyLen <= body.count {
            let count = Int(body[q])
            if count == 0 { break }
            let key = body[(q + 6)..<(q + 6 + ckeyLen)]
            q += 6 + ckeyLen
            guard q + count * ekeyLen <= body.count else { break }
            if key.elementsEqual(ckey) { return body[q..<(q + ekeyLen)] }
            q += count * ekeyLen
        }
        throw notFound
    }

    /// An install manifest's entry: a file of the game's folder (backslashed path), its content key and
    /// size, and its tags (platform, architecture, region, locale).
    struct InstallEntry: Equatable {
        var name: String
        var ckey: Data
        var size: Int
        var tags: Set<String>
    }

    static func installEntries(_ manifest: Data) throws -> [InstallEntry] {
        let d = Data(manifest)
        let bad = Failure("The build's install manifest on Blizzard's CDN isn't one Slashplayed reads.")
        guard d.count >= 10, d.prefix(2) == Data("IN".utf8) else { throw bad }
        let keyLen = Int(d[3]), tagCount = Int(be(d, 4, 2)), count = Int(be(d, 6, 4))
        let maskLen = (count + 7) / 8
        var p = 10
        func string() throws -> String {
            guard let end = d[p...].firstIndex(of: 0) else { throw bad }
            defer { p = end + 1 }
            return String(decoding: d[p..<end], as: UTF8.self)
        }
        var tags: [(String, Data)] = []
        for _ in 0..<tagCount {
            let name = try string()
            p += 2  // the tag's type
            guard p + maskLen <= d.count else { throw bad }
            tags.append((name, d[p..<(p + maskLen)]))
            p += maskLen
        }
        var out: [InstallEntry] = []
        for i in 0..<count {
            let name = try string()
            guard p + keyLen + 4 <= d.count else { throw bad }
            let set = Set(tags.filter { $0.1[$0.1.startIndex + i / 8] & (0x80 >> UInt8(i % 8)) != 0 }.map(\.0))
            out.append(InstallEntry(name: name, ckey: d[p..<(p + keyLen)], size: Int(be(d, p + keyLen, 4)), tags: set))
            p += keyLen + 4
        }
        return out
    }

    /// The content key of the Mac client at `path` for `region`. The manifest has a copy per region
    /// group (China's differs), so an entry tagged with the region wins.
    static func executableKey(_ entries: [InstallEntry], path: String, region: String) throws -> Data {
        let name = path.replacingOccurrences(of: "/", with: "\\")
        let mac = entries.filter { $0.name == name && $0.tags.contains("OSX") }
        let regional = mac.filter { $0.tags.contains(region.uppercased()) }
        let keys = Set((regional.isEmpty ? mac : regional).map(\.ckey))
        guard keys.count == 1, let key = keys.first else {
            throw Failure(keys.isEmpty ? "The build's install manifest has no Mac \(path)."
                                       : "The build's install manifest has more than one Mac \(path) for \(region).")
        }
        return key
    }

    /// The archive holding encoded key `ekey`, from the CDN config's archives' indexes (data/<archive>.index,
    /// cached), and the archives searched; nil if none has it.
    func archiveBlob(_ ekey: String, archives: [String]) async throws -> (blob: Blob, searched: [String])? {
        guard let key = Data(hex: ekey) else { return nil }
        var searched: [String] = []
        for archive in archives where Self.isKey(archive) {
            let index = try await cached("\(archive).index") { try await get(Self.path("data", archive + ".index"), nil) }
            searched.append(archive)
            if let hit = try Self.archiveIndex(index, find: key) {
                return (Blob(ekey: ekey, archive: archive, offset: hit.offset, size: hit.size), searched)
            }
        }
        return nil
    }

    /// Where `key` is in a CDN archive, from its index: blocks of (key, size, offset) entries, then a
    /// table of contents (a last key and a hash per block), then a 28-byte footer giving the sizes.
    static func archiveIndex(_ index: Data, find key: Data) throws -> (offset: Int, size: Int)? {
        let d = Data(index)
        let bad = Failure("An archive index on Blizzard's CDN isn't one Slashplayed reads.")
        guard d.count >= 28 else { throw bad }
        let f = d.count - 28
        let blockSize = Int(d[f + 11]) * 1024, offsetLen = Int(d[f + 12]), sizeLen = Int(d[f + 13])
        let keyLen = Int(d[f + 14]), hashLen = Int(d[f + 15])
        guard blockSize > 0, keyLen == key.count, (1...8).contains(offsetLen), (1...8).contains(sizeLen),
              f % (blockSize + keyLen + hashLen) == 0 else { throw bad }
        let entry = keyLen + sizeLen + offsetLen
        for block in 0..<(f / (blockSize + keyLen + hashLen)) {
            for q in stride(from: block * blockSize, through: (block + 1) * blockSize - entry, by: entry)
            where d[q..<(q + keyLen)].elementsEqual(key) {
                return (Int(be(d, q + keyLen + sizeLen, offsetLen)), Int(be(d, q + keyLen, sizeLen)))
            }
        }
        return nil
    }

    /// The arm64 slice of a Mach-O file, from its first bytes: the arm64 (not arm64e) entry of a fat
    /// header, or the whole of a thin arm64 image. What `lipo -thin arm64` writes.
    static func arm64Slice(_ head: Data, fileSize: Int) throws -> Range<Int> {
        let d = Data(head)
        let arm64: UInt64 = 0x0100_000C
        guard d.count >= 8 else { throw Failure("The client on Blizzard's CDN is too short to be a Mach-O file.") }
        let magic = be(d, 0, 4)
        if magic == 0xCFFA_EDFE {  // MH_MAGIC_64, little-endian
            guard d[4] == 0x0C, d[5] == 0, d[6] == 0, d[7] == 0x01 else { throw Failure("The client on Blizzard's CDN isn't arm64.") }
            return 0..<fileSize
        }
        guard magic == 0xCAFE_BABE || magic == 0xCAFE_BABF else { throw Failure("The client on Blizzard's CDN isn't a Mach-O file.") }
        let wide = magic == 0xCAFE_BABF, entry = wide ? 32 : 20
        for i in 0..<Int(be(d, 4, 4)) {
            let e = 8 + i * entry
            guard e + entry <= d.count else { break }
            guard be(d, e, 4) == arm64, be(d, e + 4, 4) & 0x00FF_FFFF == 0 else { continue }
            let offset = Int(wide ? be(d, e + 8, 8) : be(d, e + 8, 4)), size = Int(wide ? be(d, e + 16, 8) : be(d, e + 12, 4))
            guard offset + size <= fileSize else { break }
            return offset..<(offset + size)
        }
        throw Failure("The client on Blizzard's CDN has no arm64 slice.")
    }

    // MARK: Helpers

    /// Tries each server in turn; NotFound only if every one says 404.
    private func get(_ path: String, _ range: Range<Int>?) async throws -> Data {
        guard !servers.isEmpty else { throw Failure("No Blizzard CDN server to fetch \(path) from.") }
        var problem: Error?
        for server in servers {
            do {
                return try await fetch(server.appending(path: path), range)
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as NotFound {
                problem = problem ?? e
            } catch {
                problem = error
            }
        }
        throw problem!
    }

    /// The cached file `name` if there is one, else `make`'s bytes, kept as `name`. A nil name: no cache.
    private func cached(_ name: String?, _ make: () async throws -> Data) async throws -> Data {
        guard let name else { return try await make() }
        let url = cache.appending(path: name)
        if let data = try? Data(contentsOf: url) { return data }
        let data = try await make()
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return data
    }

    /// <kind>/ab/cd/abcd…: where the CDN keeps a config or data file.
    static func path(_ kind: String, _ key: String) -> String { "\(kind)/\(key.prefix(2))/\(key.dropFirst(2).prefix(2))/\(key)" }

    static func isKey(_ s: String) -> Bool { s.wholeMatch(of: #/[0-9a-f]{32}/#) != nil }

    static func md5(_ d: Data) -> Data { Data(Insecure.MD5.hash(data: d)) }

    /// A big-endian unsigned number of `count` bytes at `offset`.
    static func be(_ d: Data, _ offset: Int, _ count: Int) -> UInt64 {
        d[(d.startIndex + offset)..<(d.startIndex + offset + count)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data()
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(decoding: chars[i..<(i + 2)], as: UTF8.self), radix: 16) else { return nil }
            out.append(b)
        }
        self = out
    }
}
