import CryptoKit
import XCTest
import zlib

/// BlizzardCDN against a made-up CDN served from memory: builds whose version rows, configs, encoding
/// file, install manifest, archive index, and universal client are made here from our own bytes, in the
/// CDN's formats. No Blizzard file is read, except by the opt-in comparison at the end.
final class BlizzardCDNTests: XCTestCase {
    static let exePath = "World of Warcraft Classic.app/Contents/MacOS/World of Warcraft Classic"

    /// The CDN's files by host and path, served with ranges, and what was asked for.
    final class FakeCDN: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String: Data] = [:]
        private(set) var requests: [(path: String, bytes: Int)] = []

        subscript(path: String) -> Data? {
            get { lock.withLock { files[path] } }
            set { lock.withLock { files[path] = newValue } }
        }

        func reset() { lock.withLock { requests = [] } }

        /// Bytes served for paths with this prefix.
        func bytes(_ prefix: String) -> Int { lock.withLock { requests.filter { $0.path.hasPrefix(prefix) }.map(\.bytes).reduce(0, +) } }

        var fetch: BlizzardCDN.Fetch {
            { [self] url, range in
                let path = (url.host() ?? "") + url.path()
                guard let data = self[path] else { throw BlizzardCDN.NotFound(url: url) }
                let out = range.map { Data(data[$0.clamped(to: 0..<data.count)]) } ?? data
                lock.withLock { requests.append((path, out.count)) }
                return out
            }
        }
    }

    /// One build on the CDN: its keys and the client's arm64 slice.
    struct Build {
        var buildConfig: String, cdnConfig: String
        var exeKey: String
        var arm64: Data
        var encodingKey: String
        /// The encoding file's pages, its last chunk.
        var encodingPagesBytes: Int
    }

    private func md5(_ d: Data) -> Data { Data(Insecure.MD5.hash(data: d)) }
    private func be(_ v: Int, _ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * (n - 1 - $0))) }) }
    private func le32(_ v: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }) }

    private func zlibCompress(_ input: Data) -> Data {
        var length = compressBound(uLong(input.count))
        var out = [UInt8](repeating: 0, count: Int(length))
        let bytes = [UInt8](input)
        precondition(compress(&out, &length, bytes, uLong(bytes.count)) == Z_OK)
        return Data(out.prefix(Int(length)))
    }

    /// Bytes that look a little like code: compressible but not uniform.
    private func filler(_ count: Int, seed: UInt32) -> Data {
        var x = seed &* 2_654_435_761 | 1
        return Data((0..<count).map { i in
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            return i % 3 == 0 ? UInt8(truncatingIfNeeded: x) : UInt8(i % 7)
        })
    }

    /// A chunked BLTE file of `parts`, each stored (N) or zlib (Z); its encoded key is its header's MD5.
    private func blte(_ parts: [(mode: Character, content: Data)]) -> (key: String, data: Data) {
        let chunks = parts.map { p in p.mode == "Z" ? Data("Z".utf8) + zlibCompress(p.content) : Data("N".utf8) + p.content }
        var header = Data("BLTE".utf8) + be(12 + 24 * chunks.count, 4) + Data([0x0F]) + be(chunks.count, 3)
        for (c, p) in zip(chunks, parts) { header += be(c.count, 4) + be(p.content.count, 4) + md5(c) }
        return (md5(header).hex, chunks.reduce(header, +))
    }

    /// A universal file: an x86_64 slice, then the arm64 one at a 16 KB boundary.
    private func universal(arm64: Data, x86: Data) -> Data {
        let armOffset = (4096 + x86.count + 0x3FFF) & ~0x3FFF
        var d = be(0xCAFE_BABE, 4) + be(2, 4)
        d += be(0x0100_0007, 4) + be(3, 4) + be(4096, 4) + be(x86.count, 4) + be(12, 4)
        d += be(0x0100_000C, 4) + be(0, 4) + be(armOffset, 4) + be(arm64.count, 4) + be(14, 4)
        d += Data(count: 4096 - d.count) + x86
        return d + Data(count: armOffset - d.count) + arm64
    }

    /// Puts a build of product `product` on `cdn`: its executable loose, or (`loose` false) in the second
    /// of two archives. The encoding file's pages are one stored chunk, as Retail's are.
    @discardableResult
    private func addBuild(_ cdn: FakeCDN, seed: UInt32, loose: Bool = true) -> Build {
        func put(_ kind: String, _ key: String, _ data: Data) { cdn["cdn.test/tpr/wow/" + BlizzardCDN.path(kind, key)] = data }
        let arm64 = filler(50_000, seed: seed), exe = universal(arm64: arm64, x86: filler(300_000, seed: seed + 1))
        let exeContentKey = md5(exe)
        let exeBlob = blte(stride(from: 0, to: exe.count, by: 8192).enumerated().map { i, at in
            (i % 2 == 0 ? "Z" : "N", Data(exe[at..<min(at + 8192, exe.count)]))
        })

        // The install manifest (unchunked): the client for the US and for China, and a Windows file.
        let tags = ["OSX", "Windows", "US", "CN"]
        let entries: [(String, Data, Set<String>)] = [
            (Self.exePath.replacingOccurrences(of: "/", with: "\\"), exeContentKey, ["OSX", "US"]),
            (Self.exePath.replacingOccurrences(of: "/", with: "\\"), md5(Data("china \(seed)".utf8)), ["OSX", "CN"]),
            ("Wow.exe", md5(Data("windows \(seed)".utf8)), ["Windows", "US"]),
        ]
        var manifest = Data("IN".utf8) + Data([1, 16]) + be(tags.count, 2) + be(entries.count, 4)
        for tag in tags {
            let mask = entries.enumerated().reduce(UInt8(0)) { $0 | ($1.element.2.contains(tag) ? 0x80 >> UInt8($1.offset) : 0) }
            manifest += Data(tag.utf8) + Data([0]) + be(1, 2) + Data([mask])
        }
        for (name, key, _) in entries { manifest += Data(name.utf8) + Data([0]) + key + be(1234, 4) }
        let installBlob = Data("BLTE".utf8) + be(0, 4) + Data("N".utf8) + manifest
        put("data", md5(installBlob).hex, installBlob)

        // The encoding file: the client's key among 1500 others, in 1 KB pages (58 of them).
        let pairs = ([(exeContentKey, Data(hex: exeBlob.key)!)] + (0..<1500).map { (md5(Data("c\(seed).\($0)".utf8)), md5(Data("e\(seed).\($0)".utf8))) })
            .sorted { $0.0.lexicographicallyPrecedes($1.0) }
        var pages: [Data] = [], firstKeys: [Data] = []
        for (ck, ek) in pairs {
            let e = Data([1]) + be(100, 5) + ck + ek
            if pages.isEmpty || pages[pages.count - 1].count + e.count > 1024 { pages.append(Data()); firstKeys.append(ck) }
            pages[pages.count - 1] += e
        }
        pages = pages.map { $0 + Data(count: 1024 - $0.count) }
        let espec = Data("z\0".utf8)
        let head = Data("EN".utf8) + Data([1, 16, 16]) + be(1, 2) + be(1, 2) + be(pages.count, 4) + be(0, 4) + Data([0]) + be(espec.count, 4)
        let index = zip(firstKeys, pages).reduce(Data()) { $0 + $1.0 + md5($1.1) }
        let encoding = blte([("N", head), ("Z", espec), ("Z", index), ("N", pages.reduce(Data(), +))])
        put("data", encoding.key, encoding.data)

        // The client, loose or in an archive.
        var archives: [String] = []
        if loose {
            put("data", exeBlob.key, exeBlob.data)
        } else {
            for (n, holds) in [(0, false), (1, true)] {
                let name = md5(Data("archive \(seed) \(n)".utf8)).hex
                let other = (md5(Data("other \(n)".utf8)), filler(100, seed: 9))
                let stored = holds ? [other, (Data(hex: exeBlob.key)!, exeBlob.data)] : [other]
                var archive = Data(), block = Data()
                for (key, data) in stored {
                    block += key + be(data.count, 4) + be(archive.count, 4)
                    archive += data
                }
                put("data", name, archive)
                let footer = Data(count: 8) + Data([1, 0, 0, 4, 4, 4, 16, 8]) + le32(stored.count) + Data(count: 8)
                put("data", name + ".index", block + Data(count: 4096 - block.count) + Data(count: 24) + footer)
                archives.append(name)
            }
        }

        let cdnConfig = Data("# CDN Configuration\n\narchives = \(archives.joined(separator: " "))\n".utf8)
        let buildConfig = Data(("# Build Configuration\n\ninstall = \(md5(manifest).hex) \(md5(installBlob).hex)\n"
                                + "install-size = \(manifest.count) \(installBlob.count)\n"
                                + "encoding = \(md5(Data("enc".utf8)).hex) \(encoding.key)\n").utf8)
        put("config", md5(cdnConfig).hex, cdnConfig)
        put("config", md5(buildConfig).hex, buildConfig)
        return Build(buildConfig: md5(buildConfig).hex, cdnConfig: md5(cdnConfig).hex, exeKey: exeBlob.key, arm64: arm64,
                     encodingKey: encoding.key, encodingPagesBytes: pages.count * 1024)
    }

    /// Makes `build` the patch service's current one for `product`.
    private func publish(_ cdn: FakeCDN, _ product: String, _ build: Build) {
        cdn["service.test/\(product)/versions"] = Data("""
            Region!STRING:0|BuildConfig!HEX:16|CDNConfig!HEX:16|KeyRing!HEX:16|BuildId!DEC:4|VersionsName!String:0|ProductConfig!HEX:16
            ## seqn = 7
            eu|\(String(repeating: "0", count: 32))|\(build.cdnConfig)||1|1.0.0.1|
            us|\(build.buildConfig)|\(build.cdnConfig)||4321|1.2.3.4321|\(String(repeating: "e", count: 32))

            """.utf8)
        cdn["service.test/\(product)/cdns"] = Data("""
            Name!STRING:0|Path!STRING:0|Hosts!STRING:0|Servers!STRING:0|ConfigPath!STRING:0
            ## seqn = 3
            us|tpr/wow|cdn.test other.test|http://other.test/?maxhosts=8 https://cdn.test/?maxhosts=4&fallback=1 https://other.test/?fallback=1|tpr/configs/data

            """.utf8)
    }

    private func client(_ cdn: FakeCDN, partial: Int = 1 << 20) -> BlizzardCDN {
        let cache = FileManager.default.temporaryDirectory.appending(path: "sp-cdn-tests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: cache) }
        var c = BlizzardCDN(cache: cache, fetch: cdn.fetch, patchService: { _ in URL(string: "https://service.test")! })
        c.partialChunkBytes = partial
        return c
    }

    // MARK: Tests

    func testClientIsTheArm64SliceFetchedInPart() async throws {
        let cdn = FakeCDN()
        let build = addBuild(cdn, seed: 1)
        publish(cdn, "wow_test", build)
        let result = try await client(cdn).client(product: "wow_test", region: "us", executable: Self.exePath)
        XCTAssertEqual(try Data(contentsOf: result.slice), build.arm64)
        XCTAssertEqual(result.version, BlizzardCDN.Version(region: "us", buildConfig: build.buildConfig, cdnConfig: build.cdnConfig,
                                                           keyRing: "", buildID: "4321", versionsName: "1.2.3.4321",
                                                           productConfig: String(repeating: "e", count: 32)))
        XCTAssertEqual(result.buildConfig["encoding"]?.last, build.encodingKey)
        // Only the chunks covering the slice (and the header and first chunk) were fetched, not the x86 half.
        let exe = try XCTUnwrap(cdn["cdn.test/tpr/wow/" + BlizzardCDN.path("data", build.exeKey)])
        let fetched = cdn.bytes("cdn.test/tpr/wow/" + BlizzardCDN.path("data", build.exeKey))
        XCTAssertGreaterThan(exe.count, 250_000)
        XCTAssertLessThan(fetched, 100_000)
    }

    func testSecondRunFetchesNothingFromTheCDN() async throws {
        let cdn = FakeCDN()
        publish(cdn, "wow_test", addBuild(cdn, seed: 2))
        let c = client(cdn)
        let first = try await c.client(product: "wow_test", region: "us", executable: Self.exePath)
        cdn.reset()
        let again = try await c.client(product: "wow_test", region: "us", executable: Self.exePath)
        XCTAssertEqual(again.slice, first.slice)
        XCTAssertEqual(cdn.bytes("cdn.test"), 0)
        XCTAssertGreaterThan(cdn.bytes("service.test"), 0)
    }

    func testClientInAnArchive() async throws {
        let cdn = FakeCDN()
        let build = addBuild(cdn, seed: 3, loose: false)
        publish(cdn, "wow_test", build)
        let result = try await client(cdn).client(product: "wow_test", region: "us", executable: Self.exePath)
        XCTAssertEqual(try Data(contentsOf: result.slice), build.arm64)
    }

    func testEncodingPageReadAloneAndChecked() async throws {
        let cdn = FakeCDN()
        let build = addBuild(cdn, seed: 4)
        publish(cdn, "wow_test", build)
        let encodingPath = "cdn.test/tpr/wow/" + BlizzardCDN.path("data", build.encodingKey)
        let result = try await client(cdn, partial: 0).client(product: "wow_test", region: "us", executable: Self.exePath)
        XCTAssertEqual(try Data(contentsOf: result.slice), build.arm64)
        // The header probe, the header and index chunks, the mode byte, and one 1 KB page, of 58 KB.
        XCTAssertLessThan(cdn.bytes(encodingPath), BlizzardCDN.headerProbe + 4096)

        // A page that doesn't match the index's checksum is refused.
        var encoding = try XCTUnwrap(cdn[encodingPath])
        for i in (encoding.count - build.encodingPagesBytes)..<encoding.count { encoding[i] ^= 0x55 }
        cdn[encodingPath] = encoding
        do {
            _ = try await client(cdn, partial: 0).client(product: "wow_test", region: "us", executable: Self.exePath)
            XCTFail("a corrupt encoding page was read")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checksum"), error.localizedDescription)
        }
    }

    func testCorruptChunkIsRefused() async throws {
        let cdn = FakeCDN()
        let build = addBuild(cdn, seed: 5)
        publish(cdn, "wow_test", build)
        let path = "cdn.test/tpr/wow/" + BlizzardCDN.path("data", build.exeKey)
        var exe = try XCTUnwrap(cdn[path])
        exe[exe.count - 10] ^= 0xFF
        cdn[path] = exe
        do {
            _ = try await client(cdn).client(product: "wow_test", region: "us", executable: Self.exePath)
            XCTFail("a corrupt chunk was decoded")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checksum"), error.localizedDescription)
        }
    }

    func testANewBuildPrunesTheOldOne() async throws {
        let cdn = FakeCDN()
        let old = addBuild(cdn, seed: 6), other = addBuild(cdn, seed: 7)
        publish(cdn, "wow_test", old)
        publish(cdn, "wow_other", other)
        let c = client(cdn)
        let oldSlice = try await c.client(product: "wow_test", region: "us", executable: Self.exePath).slice
        let otherSlice = try await c.client(product: "wow_other", region: "us", executable: Self.exePath).slice

        let new = addBuild(cdn, seed: 8)
        publish(cdn, "wow_test", new)
        let newSlice = try await c.client(product: "wow_test", region: "us", executable: Self.exePath).slice
        let names = try FileManager.default.contentsOfDirectory(atPath: c.cache.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldSlice.path))
        XCTAssertFalse(names.contains { $0.hasPrefix(old.buildConfig) || $0.hasPrefix(old.encodingKey) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: newSlice.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherSlice.path))
        XCTAssertTrue(names.contains(other.buildConfig))
    }

    func testServersAreTheRegionsHTTPSOnes() async throws {
        let cdn = FakeCDN()
        publish(cdn, "wow_test", addBuild(cdn, seed: 9))
        let servers = try await client(cdn).connected(product: "wow_test", region: "us").servers
        XCTAssertEqual(servers.map(\.absoluteString), ["https://cdn.test/tpr/wow", "https://other.test/tpr/wow"])
        do {
            _ = try await client(cdn).version(product: "wow_test", region: "u.s")
            XCTFail("a region that isn't a host name label went into a URL")
        } catch {}
    }

    func testArm64SliceOfEachKindOfMachO() throws {
        let arm = filler(100, seed: 10)
        let fat = universal(arm64: arm, x86: filler(50, seed: 11))
        let range = try BlizzardCDN.arm64Slice(fat.prefix(4096), fileSize: fat.count)
        XCTAssertEqual(fat[range], arm)
        // FAT_MAGIC_64, with an arm64e entry first, which `lipo -thin arm64` doesn't take.
        var fat64 = be(0xCAFE_BABF, 4) + be(2, 4)
        fat64 += be(0x0100_000C, 4) + be(2, 4) + be(4096, 8) + be(10, 8) + be(14, 4) + be(0, 4)
        fat64 += be(0x0100_000C, 4) + be(0, 4) + be(8192, 8) + be(20, 8) + be(14, 4) + be(0, 4)
        XCTAssertEqual(try BlizzardCDN.arm64Slice(fat64, fileSize: 8212), 8192..<8212)
        let thin = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0, 0, 0x01]) + Data(count: 24)
        XCTAssertEqual(try BlizzardCDN.arm64Slice(thin, fileSize: 5000), 0..<5000)
        XCTAssertThrowsError(try BlizzardCDN.arm64Slice(Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0, 0, 0x01]), fileSize: 8))
    }

    func testExecutableKeyFollowsTheRegion() throws {
        let us = md5(Data("us".utf8)), cn = md5(Data("cn".utf8))
        let name = Self.exePath.replacingOccurrences(of: "/", with: "\\")
        let entries = [BlizzardCDN.InstallEntry(name: name, ckey: cn, size: 1, tags: ["OSX", "CN"]),
                       BlizzardCDN.InstallEntry(name: name, ckey: us, size: 1, tags: ["OSX", "US", "EU"]),
                       BlizzardCDN.InstallEntry(name: name, ckey: md5(Data("win".utf8)), size: 1, tags: ["Windows", "US"])]
        XCTAssertEqual(try BlizzardCDN.executableKey(entries, path: Self.exePath, region: "us"), us)
        XCTAssertEqual(try BlizzardCDN.executableKey(entries, path: Self.exePath, region: "eu"), us)
        XCTAssertEqual(try BlizzardCDN.executableKey(entries, path: Self.exePath, region: "cn"), cn)
        XCTAssertThrowsError(try BlizzardCDN.executableKey(entries, path: Self.exePath, region: "kr"))  // two candidates
        XCTAssertThrowsError(try BlizzardCDN.executableKey(entries, path: "Other.app/Contents/MacOS/Other", region: "us"))
    }

    /// A .build.info written from the patch service's rows has Battle.net's header and a row laid out as an
    /// install's, the install's own columns empty, and reads back as the rows it was made from.
    func testBuildInfoFromServiceRows() throws {
        let key = String(repeating: "a1", count: 16), cdnKey = String(repeating: "b2", count: 16), ring = String(repeating: "c3", count: 16)
        let version = BlizzardCDN.Version(region: "us", buildConfig: key, cdnConfig: cdnKey, keyRing: ring, buildID: "1",
                                          versionsName: "12.1.5.1", productConfig: "")
        let cdns = BlizzardCDN.CDNs(path: "tpr/wow", hosts: "a.example b.example", servers: "https://a.example/?maxhosts=4")
        let line = BlizzardCDN.buildInfoLine(product: "wow", version: version, cdns: cdns, tags: "OSX enUS text?")
        XCTAssertEqual(line, "us|1|\(key)|\(cdnKey)|||tpr/wow|a.example b.example|https://a.example/?maxhosts=4|OSX enUS text?|||12.1.5.1|\(ring)|wow")
        let text = GameStore.buildInfoText([line])
        XCTAssertEqual(text.split(separator: "\n").first,
                       "Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|CDN Key!HEX:16|Install Key!HEX:16|IM Size!DEC:4|CDN Path!STRING:0|"
                       + "CDN Hosts!STRING:0|CDN Servers!STRING:0|Tags!STRING:0|Armadillo!STRING:0|Last Activated!STRING:0|"
                       + "Version!STRING:0|KeyRing!HEX:16|Product!STRING:0")
        let row = try XCTUnwrap(GameStore.BuildInfo(text)?.byProduct["wow"])
        XCTAssertEqual(row["Build Key"], key)
        XCTAssertEqual(row["KeyRing"], ring)
        XCTAssertEqual(row["Branch"], "us")
        XCTAssertEqual(row["CDN Servers"], cdns.servers)
        XCTAssertEqual(row["Install Key"], "")
        // A device's newer row for the product is kept over it, as for the Mac's rows.
        let newer = text.replacingOccurrences(of: "12.1.5.1", with: "12.1.5.2")
        XCTAssertEqual(GameStore.deviceBuildInfo(mac: text, device: newer).newer, ["wow"])
    }

    /// `connected` keeps the region's cdns row, for .build.info.
    func testConnectedKeepsTheCDNRow() async throws {
        let cdn = BlizzardCDN(cache: FileManager.default.temporaryDirectory, fetch: { url, _ in
            guard url.lastPathComponent == "cdns" else { throw BlizzardCDN.NotFound(url: url) }
            return Data("Name!STRING:0|Path!STRING:0|Hosts!STRING:0|Servers!STRING:0|ConfigPath!STRING:0\n## seqn = 1\n"
                        .appending("us|tpr/wow|h1 h2|http://h1/?x=1 https://h2/?x=2|tpr/configs/data\n").utf8)
        })
        let connected = try await cdn.connected(product: "wow", region: "us")
        XCTAssertEqual(connected.cdns, BlizzardCDN.CDNs(path: "tpr/wow", hosts: "h1 h2", servers: "http://h1/?x=1 https://h2/?x=2"))
        XCTAssertEqual(connected.servers, [URL(string: "https://h2/tpr/wow")!])
    }

    // MARK: The launcher's port (apps/client/spcdn.m)

    final class Box: @unchecked Sendable {
        var data: Data?
        var problem: String?
    }

    /// `fetch` as the launcher's SPFetch: blocking, a 404 reported as SPCDNNotFound.
    static func launcherFetch(_ fetch: @escaping BlizzardCDN.Fetch) -> SPFetch {
        { url, range, problem in
            let done = DispatchSemaphore(value: 0), box = Box()
            Task.detached {
                do {
                    box.data = try await fetch(url, range.length > 0 ? range.location..<(range.location + range.length) : nil)
                } catch is BlizzardCDN.NotFound {
                    box.problem = SPCDNNotFound
                } catch {
                    box.problem = error.localizedDescription
                }
                done.signal()
            }
            done.wait()
            if box.data == nil { problem.pointee = box.problem as NSString? }
            return box.data
        }
    }

    /// The launcher's port on `cdn`: the servers it takes from the cdns table, and the slice it writes or
    /// why it couldn't.
    private func launcherSlice(_ cdn: FakeCDN, _ product: String, _ build: Build) throws
        -> (servers: [URL], slice: Data?, problem: String?, tags: [String]?) {
        let cdns = String(decoding: try XCTUnwrap(cdn["service.test/\(product)/cdns"]), as: UTF8.self)
        let servers = sp_cdn_servers(try XCTUnwrap(sp_table_row(cdns, "Name", "us")))
        let out = FileManager.default.temporaryDirectory.appending(path: "sp-cdn-port-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        var problem: NSString?
        var tags: NSArray?
        let ok = sp_cdn_slice(servers, build.buildConfig, build.cdnConfig, Self.exePath, "us", Self.launcherFetch(cdn.fetch),
                              out.path, &tags, &problem)
        return (servers, ok ? try Data(contentsOf: out) : nil, problem as String?, tags as? [String])
    }

    func testLauncherPortFetchesTheSameSlice() async throws {
        let cdn = FakeCDN()
        let loose = addBuild(cdn, seed: 21), archived = addBuild(cdn, seed: 22, loose: false)
        publish(cdn, "wow_test", loose)
        publish(cdn, "wow_archived", archived)
        let expected = try await client(cdn).connected(product: "wow_test", region: "us").servers
        cdn.reset()
        let port = try launcherSlice(cdn, "wow_test", loose)
        XCTAssertEqual(port.servers, expected)
        XCTAssertEqual(port.slice, loose.arm64, port.problem ?? "")
        // The install manifest's tag names come back, for the launcher's check of the locales a build ships.
        XCTAssertEqual(port.tags, ["OSX", "Windows", "US", "CN"])
        // In part, as the companion's: not the x86 half.
        XCTAssertLessThan(cdn.bytes("cdn.test/tpr/wow/" + BlizzardCDN.path("data", loose.exeKey)), 100_000)
        let inArchive = try launcherSlice(cdn, "wow_archived", archived)
        XCTAssertEqual(inArchive.slice, archived.arm64, inArchive.problem ?? "")
    }

    func testLauncherPortRefusesACorruptChunk() throws {
        let cdn = FakeCDN()
        let build = addBuild(cdn, seed: 23)
        publish(cdn, "wow_test", build)
        let path = "cdn.test/tpr/wow/" + BlizzardCDN.path("data", build.exeKey)
        var exe = try XCTUnwrap(cdn[path])
        exe[exe.count - 10] ^= 0xFF
        cdn[path] = exe
        let port = try launcherSlice(cdn, "wow_test", build)
        XCTAssertNil(port.slice)
        XCTAssertTrue(port.problem?.contains("checksum") == true, port.problem ?? "")
    }

    func testLauncherPortSaysWhenTheClientIsGone() throws {
        let cdn = FakeCDN()
        let build = addBuild(cdn, seed: 24)
        publish(cdn, "wow_test", build)
        cdn["cdn.test/tpr/wow/" + BlizzardCDN.path("data", build.exeKey)] = nil
        let port = try launcherSlice(cdn, "wow_test", build)
        XCTAssertNil(port.slice)
        XCTAssertTrue(port.problem?.contains("doesn't have the client") == true, port.problem ?? "")
    }

    /// An update on the device writes the configs of the new build's row as the companion does
    /// (GameFiles.build, from configData): the same bytes at config/ab/cd/<key>, fetched only when the file
    /// there isn't that config, and refused when the CDN's bytes don't match the key.
    func testLauncherPortStoresConfigsAsTheCompanion() async throws {
        let cdn = FakeCDN()
        let build = addBuild(cdn, seed: 25)
        publish(cdn, "wow_test", build)
        let companion = try await client(cdn).connected(product: "wow_test", region: "us")
        let cdns = String(decoding: try XCTUnwrap(cdn["service.test/wow_test/cdns"]), as: UTF8.self)
        let servers = sp_cdn_servers(try XCTUnwrap(sp_table_row(cdns, "Name", "us")))
        let data = FileManager.default.temporaryDirectory.appending(path: "sp-cdn-configs-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: data) }
        let fetch = Self.launcherFetch(cdn.fetch)
        for key in [build.buildConfig, build.cdnConfig] {
            var fetched: UInt64 = 0
            var problem: NSString?
            XCTAssertTrue(sp_cdn_store_config(servers, key, fetch, data.path, &fetched, &problem), problem as String? ?? "")
            let written = try Data(contentsOf: data.appending(path: "config/\(key.prefix(2))/\(key.dropFirst(2).prefix(2))/\(key)"))
            let expected = try await companion.configData(key)
            XCTAssertEqual(written, expected)
            XCTAssertEqual(fetched, UInt64(expected.count))
            // Already there: nothing fetched.
            cdn.reset()
            XCTAssertTrue(sp_cdn_store_config(servers, key, fetch, data.path, &fetched, &problem))
            XCTAssertEqual(fetched, 0)
            XCTAssertEqual(cdn.bytes(""), 0)
        }
        // A file there that isn't the config is replaced.
        let path = data.appending(path: "config/\(build.buildConfig.prefix(2))/\(build.buildConfig.dropFirst(2).prefix(2))/\(build.buildConfig)")
        try Data("not it".utf8).write(to: path)
        var fetched: UInt64 = 0
        var problem: NSString?
        XCTAssertTrue(sp_cdn_store_config(servers, build.buildConfig, fetch, data.path, &fetched, &problem))
        XCTAssertGreaterThan(fetched, 0)
        // The CDN's bytes that don't match the key aren't written.
        let bad = String(repeating: "d4", count: 16)
        cdn["cdn.test/tpr/wow/" + BlizzardCDN.path("config", bad)] = Data("something else".utf8)
        XCTAssertFalse(sp_cdn_store_config(servers, bad, fetch, data.path, &fetched, &problem))
        XCTAssertTrue(problem?.contains("doesn't match") == true, problem as String? ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appending(path: "config/d4/d4/\(bad)").path))
    }

    /// The .build.info an update on the device writes is the one the companion writes for that build
    /// (BlizzardCDN.buildInfoLine under GameStore.buildInfoText; GameStore.deviceBuildInfo with the device's
    /// other rows), its Tags kept from the device's row.
    func testLauncherPortWritesTheCompanionsBuildInfo() throws {
        func version(_ n: String, ring: String = "") -> BlizzardCDN.Version {
            BlizzardCDN.Version(region: "us", buildConfig: String(repeating: n, count: 32), cdnConfig: String(repeating: "c", count: 32),
                                keyRing: ring, buildID: "1", versionsName: "1.15.9.\(n == "a" ? "69722" : "70003")", productConfig: "")
        }
        let cdns = BlizzardCDN.CDNs(path: "tpr/wow", hosts: "h1.example h2.example", servers: "http://h1.example/?x=1 https://h2.example/?x=2")
        let tags = "OSX arm64 EU? enGB speech?:OSX arm64 EU? enGB text?"
        let old = BlizzardCDN.buildInfoLine(product: "wow_classic_era", version: version("a"), cdns: cdns, tags: tags)
        let new = version("b")
        let expected = GameStore.buildInfoText([BlizzardCDN.buildInfoLine(product: "wow_classic_era", version: new, cdns: cdns, tags: tags)])
        // The service's rows, as the launcher has them.
        let versionRow = ["Region": "us", "BuildConfig": new.buildConfig, "CDNConfig": new.cdnConfig, "KeyRing": new.keyRing,
                          "BuildId": "1", "VersionsName": new.versionsName, "ProductConfig": ""]
        let cdnsRow = ["Name": "us", "Path": cdns.path, "Hosts": cdns.hosts, "Servers": cdns.servers, "ConfigPath": "tpr/configs/data"]
        func device(_ existing: String?) -> String {
            sp_build_info_with(existing, "wow_classic_era", "us", nil, versionRow, cdnsRow)
        }
        XCTAssertEqual(device(GameStore.buildInfoText([old])), expected)
        // Another product's row stays where it was; the result is the companion's for both builds.
        let retail = BlizzardCDN.buildInfoLine(product: "wow", version: version("e", ring: String(repeating: "f", count: 32)),
                                               cdns: cdns, tags: tags)
        let both = GameStore.buildInfoText([retail, old])
        let mac = GameStore.buildInfoText([retail, BlizzardCDN.buildInfoLine(product: "wow_classic_era", version: new, cdns: cdns, tags: tags)])
        XCTAssertEqual(device(both), mac)
        XCTAssertEqual(device(both), GameStore.deviceBuildInfo(mac: mac, device: both).text)
        // No .build.info, or no row for the product: a row at the end, with the default Tags.
        let defaultTags = "OSX x86_64 US? acct-USA? geoip-US? enUS speech?:OSX x86_64 US? acct-USA? geoip-US? enUS text?"
        let fresh = GameStore.buildInfoText([BlizzardCDN.buildInfoLine(product: "wow_classic_era", version: new, cdns: cdns, tags: defaultTags)])
        XCTAssertEqual(device(nil), fresh)
        XCTAssertEqual(device(GameStore.buildInfoText([retail])),
                       GameStore.buildInfoText([retail, BlizzardCDN.buildInfoLine(product: "wow_classic_era", version: new, cdns: cdns,
                                                                                    tags: defaultTags)]))
        // A device file in another column order is laid out in Battle.net's, by name.
        let table = try XCTUnwrap(GameStore.BuildInfo(both))
        let columns = GameStore.buildInfoColumns.reversed()
        let reordered = ([columns.map { "\($0.name)!\($0.type)" }.joined(separator: "|")]
                         + table.lines.map { l in columns.map { table.row(l)[$0.name] ?? "" }.joined(separator: "|") })
            .map { $0 + "\n" }.joined()
        XCTAssertEqual(device(reordered), mac)
    }

    /// The row an image made on the device keeps beside it (update's sp_build_info_with with no existing
    /// rows) goes into the game data's .build.info on any launch whose row isn't the image's build: what
    /// the update itself would have written, with the device's Tags and other products' rows kept (#36: a
    /// launch that stopped before the client loaded, or game data emptied under the image).
    func testLauncherPortWritesAnImagesKeptRow() throws {
        func version(_ n: String) -> BlizzardCDN.Version {
            BlizzardCDN.Version(region: "us", buildConfig: String(repeating: n, count: 32), cdnConfig: String(repeating: "c", count: 32),
                                keyRing: "", buildID: "1", versionsName: "1.15.9.\(n == "a" ? "69722" : "70003")", productConfig: "")
        }
        let cdns = BlizzardCDN.CDNs(path: "tpr/wow", hosts: "h1.example", servers: "http://h1.example/?x=1")
        let cdnsRow = ["Name": "us", "Path": cdns.path, "Hosts": cdns.hosts, "Servers": cdns.servers]
        let new = version("b")
        let versionRow = ["Region": "us", "BuildConfig": new.buildConfig, "CDNConfig": new.cdnConfig, "KeyRing": new.keyRing,
                          "VersionsName": new.versionsName]
        let kept = sp_build_info_with(nil, "wow_classic_era", "us", nil, versionRow, cdnsRow)
        let stamp = "Product!STRING:0|Branch!STRING:0|Build Key!HEX:16|Version!STRING:0\n"
            + "wow_classic_era|us|\(new.buildConfig)|\(new.versionsName)\n"
        func heal(_ existing: String?, kept: String? = kept, stamp: String = stamp) -> (String?, String?) {
            var why: NSString?
            let text = sp_build_info_for_image(existing, "wow_classic_era", kept, stamp, nil, &why)
            return (text, why as String?)
        }
        // No .build.info at all (an install into an empty container): the row the update would have written.
        XCTAssertEqual(heal(nil).0, sp_build_info_with(nil, "wow_classic_era", "us", nil, versionRow, cdnsRow))
        XCTAssertNil(heal(nil).1)
        // Another build's row, another product beside it, and the device's own Tags: as the update writes it.
        let tags = "OSX arm64 EU? enGB speech?:OSX arm64 EU? enGB text?"
        let retail = BlizzardCDN.buildInfoLine(product: "wow", version: version("e"), cdns: cdns, tags: tags)
        let old = GameStore.buildInfoText([retail, BlizzardCDN.buildInfoLine(product: "wow_classic_era", version: version("a"),
                                                                             cdns: cdns, tags: tags)])
        XCTAssertEqual(heal(old).0, sp_build_info_with(old, "wow_classic_era", "us", nil, versionRow, cdnsRow))
        // Already the image's build: nothing to write, nothing to say.
        let current = try XCTUnwrap(heal(old).0)
        XCTAssertNil(heal(current).0)
        XCTAssertNil(heal(current).1)
        // Nothing kept, or another build's row kept: nothing written, and the log says why.
        XCTAssertNil(heal(nil, kept: nil).0)
        XCTAssertNotNil(heal(nil, kept: nil).1)
        let other = sp_build_info_with(nil, "wow_classic_era", "us", nil, ["BuildConfig": version("a").buildConfig, "CDNConfig": "c"], cdnsRow)
        XCTAssertNil(heal(nil, kept: other).0)
        XCTAssertNotNil(heal(nil, kept: other).1)
    }

    func testLauncherPortComparesVersionsAsTheCompanion() {
        let pairs = [("1.15.9.70003", "1.15.9.69722"), ("1.15.9.69722", "1.15.9.70003"), ("1.15.9", "1.15.9.0"), ("1.15.10.1", "1.15.9.9"),
                     ("12.0.1.1", "1.15.9.70003"), ("1.15.9.70003", "1.15.9.70003"), ("1.15.x", "1.15.9"), ("", "1.0"), ("2", "1.9")]
        for (a, b) in pairs {
            XCTAssertEqual(sp_version_newer(a, b), GameStore.isVersion(a, newerThan: b), "\(a) vs \(b)")
        }
    }

    /// Opt-in, local only (reads an installed client, fetches from Blizzard's CDN): the arm64
    /// slice of the installed build from the CDN must equal `lipo -thin arm64` of the installed
    /// executable. Uses the install's build (the CDN's current one once Battle.net has updated it), and
    /// says whether it's current. Run the tests with TEST_RUNNER_SP_COMPARE_CDN=1 (SP_INSTALL as for
    /// build.sh; TEST_RUNNER_SP_COMPARE_FLAVOR=retail or anniversary for another game than Classic Era,
    /// Retail being the one whose encoding pages are read in part). Nothing it fetches is kept: its cache
    /// is in $TMPDIR and deleted.
    func testSliceMatchesTheInstalledClient() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SP_COMPARE_CDN"] == "1" else { throw XCTSkip("set SP_COMPARE_CDN=1 to compare with the installed client") }
        let install = URL(fileURLWithPath: env["SP_INSTALL"] ?? "/Applications/World of Warcraft")
        let flavor = try XCTUnwrap(Flavor(rawValue: env["SP_COMPARE_FLAVOR"] ?? "classic_era"))
        let row = try XCTUnwrap(try GameStore.buildInfo(install)[flavor.product])
        let buildKey = try XCTUnwrap(row["Build Key"]), cdnKey = try XCTUnwrap(row["CDN Key"])
        let region = try XCTUnwrap(row["Branch"]).lowercased()

        let scratch = FileManager.default.temporaryDirectory.appending(path: "sp-cdn-compare-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let counted = Counter()
        let cdn = BlizzardCDN(cache: scratch.appending(path: "cdn"), fetch: { url, range in
            let data = try await BlizzardCDN.session(url, range)
            counted.add(data.count)
            return data
        })
        let current = try await cdn.version(product: flavor.product, region: region)
        print("cdn compare: installed \(row["Version"] ?? "?"), current \(current.versionsName)"
              + (current.buildConfig == buildKey ? "" : " (the install isn't the current build)"))
        let start = Date()
        let connected = try await cdn.connected(product: flavor.product, region: region)
        let slice = try await connected.slice(product: flavor.product, region: region, buildConfig: buildKey,
                                              cdnConfig: cdnKey, executable: flavor.clientPath).slice
        print("cdn compare: \(counted.bytes) bytes in \(counted.requests) requests, \(String(format: "%.1f", Date().timeIntervalSince(start))) s")

        let thinned = scratch.appending(path: "thin")
        try await Shell.run(ClientAssembly.xcrun, ["lipo", "-thin", "arm64", flavor.clientExecutable(in: install).path,
                                                   "-output", thinned.path])
        let ours = try Data(contentsOf: slice), lipo = try Data(contentsOf: thinned)
        XCTAssertEqual(ours.count, lipo.count)
        XCTAssertTrue(ours == lipo, "the CDN's arm64 slice differs from lipo -thin arm64 of the installed client")

        // The launcher's port (apps/client/spcdn.m) with the device's own fetch (URLSession), on its own
        // thread as on the device: the same bytes.
        let port = scratch.appending(path: "port")
        let servers = connected.servers
        let portStart = Date()
        let problem: String? = await withCheckedContinuation { done in
            Thread {
                var problem: NSString?
                let fetch = sp_cdn_session({ CFRunLoopRunInMode(.defaultMode, $0, true) }, 20, nil)
                let ok = sp_cdn_slice(servers, buildKey, cdnKey, flavor.clientPath, region, fetch, port.path, nil, &problem)
                done.resume(returning: ok ? nil : (problem as String? ?? "failed"))
            }.start()
        }
        XCTAssertNil(problem)
        print("cdn compare: the launcher's port took \(String(format: "%.1f", Date().timeIntervalSince(portStart))) s")
        XCTAssertTrue(try Data(contentsOf: port) == lipo, "the launcher's arm64 slice differs from lipo -thin arm64 of the installed client")
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var bytes = 0, requests = 0
        func add(_ n: Int) { lock.withLock { bytes += n; requests += 1 } }
    }
}
