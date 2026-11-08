import XCTest
import zlib

/// GameStore on a small store built here in the install's on-disk format (.build.info, build configs,
/// local .idx files, data.NNN archives holding BLTE-encoded encoding files), with made-up keys: no
/// Blizzard file is read, except by the opt-in comparison at the end. Also MacIdentity against the C
/// helper it replaces.
final class GameStoreTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../..").standardizedFileURL

    /// A made-up 16-byte key, `n` in its first byte, so the first 9 bytes differ between keys.
    private func key(_ n: UInt8) -> [UInt8] { [n] + (1..<16).map { UInt8($0) ^ n } }
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    /// The store: product_a's encoding file lists keys 1 (archive 1), 2 (archive 2) and 9 (in no index);
    /// product_b's lists 2 and 3 (archive 3). Both encoding files are in archive 0, product_a's as a
    /// chunked BLTE (one zlib chunk, one plain), product_b's as a single unchunked plain one. Bucket 0
    /// also has an older index sending key 1 to archive 5, which must be ignored.
    private func makeStore() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "sp-gamestore-tests-\(UUID().uuidString)")
        let data = root.appending(path: "Data/data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        var archives: [Int: Data] = [:]
        var buckets: [Int: [(key: [UInt8], archive: Int, offset: Int, size: Int)]] = [:]
        /// Stores `content` in an archive behind a 30-byte local header, indexed in `bucket`.
        func store(_ k: [UInt8], _ content: Data, archive: Int, bucket: Int) {
            let offset = archives[archive, default: Data()].count
            let block = Data(count: 30) + content
            archives[archive, default: Data()].append(block)
            buckets[bucket, default: []].append((k, archive, offset, block.count))
        }
        for (n, archive) in [(1, 1), (2, 2), (3, 3)] as [(UInt8, Int)] {
            store(key(n), Data("BLTE".utf8) + be32(0) + Data("N block \(n)".utf8), archive: archive, bucket: Int(n) % 2)
        }

        let encA = encodingFile([[key(1), key(2)], [key(9)]]), encB = encodingFile([[key(2), key(3)]])
        let half = encA.count / 2
        let chunkZ = Data("Z".utf8) + deflate(encA.prefix(half)), chunkN = Data("N".utf8) + encA.dropFirst(half)
        var bltA = Data("BLTE".utf8) + be32(UInt32(12 + 2 * 24)) + Data([0x0F, 0, 0, 2])
        for c in [chunkZ, chunkN] { bltA += be32(UInt32(c.count)) + be32(0) + Data(count: 16) }
        bltA += chunkZ + chunkN
        store(key(0xA0), bltA, archive: 0, bucket: 0)
        store(key(0xB0), Data("BLTE".utf8) + be32(0) + Data("N".utf8) + encB, archive: 0, bucket: 1)

        for (n, content) in archives {
            try content.write(to: data.appending(path: String(format: "data.%03d", n)))
        }
        for (bucket, entries) in buckets {
            try index(entries).write(to: data.appending(path: String(format: "%02x%08x.idx", bucket, 2)))
        }
        try index([(key(1), 5, 0, 10)]).write(to: data.appending(path: String(format: "%02x%08x.idx", 0, 1)))

        // product_b's build config is found by its client's build (installTable): two more build configs
        // pointing at product_a's encoding file miss it by one detail each, the build or the product.
        for (n, uid, name, enc) in [(0xC1, "product_a", "WOW-100patch1.0.0_Retail", key(0xA0)),
                                    (0xC2, "product_b", "WOW-456patch1.2.3_ClassicRetail", key(0xB0)),
                                    (0xC3, "product_b", "WOW-455patch1.2.3_ClassicRetail", key(0xA0)),
                                    (0xC4, "product_c", "WOW-456patch1.2.3_ClassicRetail", key(0xA0))] as [(UInt8, String, String, [UInt8])] {
            let buildKey = hex(key(n))
            let dir = root.appending(path: "Data/config/\(buildKey.prefix(2))/\(buildKey.dropFirst(2).prefix(2))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "# Build Configuration\n\nroot = 00\nbuild-name = \(name)\nbuild-uid = \(uid)\nencoding = \(hex(key(0xEE))) \(hex(enc))\nencoding-size = 1 2\n"
                .write(to: dir.appending(path: buildKey), atomically: true, encoding: .utf8)
        }
        // product_a has a row; product_b is installed in _b_ (its .flavor.info and client) but has none, as
        // Battle.net left four of five games out of the file on 2026-11-07.
        try """
            Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|Version!STRING:0|Product!STRING:0
            us|1|\(hex(key(0xC1)))|1.0.0.100|product_a

            """.write(to: root.appending(path: ".build.info"), atomically: true, encoding: .utf8)
        for (folder, product, version) in [("_a_", "product_a", "1.0.0.100"), ("_b_", "product_b", "1.2.3.456")] {
            let contents = root.appending(path: "\(folder)/Game.app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try "Product Flavor!STRING:0\n\(product)\n".write(to: root.appending(path: "\(folder)/.flavor.info"), atomically: true, encoding: .utf8)
            XCTAssertTrue(NSDictionary(dictionary: ["CFBundleVersion": version]).write(to: contents.appending(path: "Info.plist"), atomically: true))
        }
        return root
    }

    /// A game the install's .build.info doesn't list gets the row its folder and Data/config say: the build
    /// config of its client's build, not another build of it or another game's same build. A listed game
    /// keeps the file's row.
    func testRowForAnInstalledGameTheFileLeavesOut() throws {
        let rows = try GameStore.buildInfo(try makeStore())
        XCTAssertEqual(rows["product_b"], ["Branch": "", "Active": "", "Build Key": hex(key(0xC2)), "Version": "1.2.3.456",
                                           "Product": "product_b"])
        XCTAssertEqual(rows["product_a"], ["Branch": "us", "Active": "1", "Build Key": hex(key(0xC1)), "Version": "1.0.0.100",
                                           "Product": "product_a"])
        XCTAssertEqual(rows.count, 2)
    }

    func testArchivesPerProduct() throws {
        let root = try makeStore()
        let a = try GameStore.archives(root: root, products: ["product_a"])
        XCTAssertEqual(a.archives, [0, 1, 2])
        XCTAssertEqual(a.found["product_a"]?.found, 2)
        XCTAssertEqual(a.found["product_a"]?.total, 3)
        XCTAssertEqual(try GameStore.archives(root: root, products: ["product_b"]).archives, [0, 2, 3])
        XCTAssertEqual(try GameStore.archives(root: root, products: ["product_a", "product_b"]).archives, [0, 1, 2, 3])
    }

    func testUnknownProductFails() throws {
        XCTAssertThrowsError(try GameStore.archives(root: try makeStore(), products: ["wow_nope"]))
    }

    /// The synthetic store gives casc_archives.py's answer too, so it's in the format the script reads.
    func testMatchesPythonOnSyntheticStore() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("no /usr/bin/python3") }
        let root = try makeStore()
        for products in [["product_a"], ["product_b"], ["product_a", "product_b"]] {
            XCTAssertEqual(try GameStore.archives(root: root, products: products).archives,
                           try python(root, products), "\(products)")
        }
    }

    /// Opt-in, on the owner's real install (read only): Swift and casc_archives.py agree for each single
    /// installed flavor and each pair. Run the tests with TEST_RUNNER_SP_COMPARE_STORE=1 (SP_INSTALL as
    /// for build.sh).
    func testMatchesPythonOnInstall() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SP_COMPARE_STORE"] == "1" else { throw XCTSkip("set SP_COMPARE_STORE=1 to compare with casc_archives.py") }
        let root = URL(fileURLWithPath: env["SP_INSTALL"] ?? "/Applications/World of Warcraft")
        let products = try GameStore.buildInfo(root).keys.filter(Flavor.allCases.map(\.product).contains).sorted()
        var sets = products.map { [$0] }
        for i in products.indices { for j in products.indices where j > i { sets.append([products[i], products[j]]) } }
        for set in sets {
            let swift = try GameStore.archives(root: root, products: set).archives
            XCTAssertEqual(swift, try python(root, set), "\(set)")
            print("compare: \(set.joined(separator: " + ")): \(swift.count) archives, identical")
        }
    }

    func testMacIdentityMatchesCHelper() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sp-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appending(path: "mac-identity"), out = dir.appending(path: "spidentity")
        try run("/usr/bin/xcrun", ["clang", "-o", tool.path, Self.repo.appending(path: "shims/ident/mac-identity.c").path])
        try run(tool.path, [out.path])
        let swift = try MacIdentity.contents()
        XCTAssertFalse(swift.isEmpty)
        XCTAssertEqual(swift, try Data(contentsOf: out))
    }

    // MARK: Format writers

    /// An encoding file with one content-key page per entry of `pages`, each entry's encoded keys under
    /// one made-up content key. 1 KB pages, no encoding specs worth reading (espec is a lone NUL).
    private func encodingFile(_ pages: [[[UInt8]]]) -> Data {
        let espec = Data([0])
        var d = Data("EN".utf8) + Data([1, 16, 16]) + Data([0, 1, 0, 1]) + be32(UInt32(pages.count)) + be32(0)
            + Data([0]) + be32(UInt32(espec.count))
        d += espec
        for _ in pages { d += Data(count: 32) }  // page index: first key and checksum, unread
        for (i, keys) in pages.enumerated() {
            var page = Data([UInt8(keys.count)]) + Data(count: 5) + Data(key(0xD0 + UInt8(i)))
            for k in keys { page += Data(k) }
            page += Data(count: 1024 - page.count)
            d += page
        }
        return d
    }

    /// A v7 local index: 9-byte key prefix, 5-byte big-endian archive<<30|offset, little-endian size.
    private func index(_ entries: [(key: [UInt8], archive: Int, offset: Int, size: Int)]) -> Data {
        var header = Data(count: 0x28)
        header[8] = 7
        header.replaceSubrange(12..<16, with: [4, 5, 9, 30])
        header.replaceSubrange(0x20..<0x24, with: le32(UInt32(entries.count * 18)))
        var d = header
        for e in entries {
            let loc = UInt64(e.archive) << 30 | UInt64(e.offset)
            d += Data(e.key.prefix(9)) + Data((0..<5).map { UInt8(truncatingIfNeeded: loc >> (8 * (4 - $0))) })
            d += le32(UInt32(e.size))
        }
        return d
    }

    private func be32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * (3 - $0))) }) }
    private func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }) }

    private func deflate(_ input: Data) -> Data {
        var length = compressBound(uLong(input.count))
        var out = [UInt8](repeating: 0, count: Int(length))
        let bytes = [UInt8](input)
        precondition(compress(&out, &length, bytes, uLong(bytes.count)) == Z_OK)
        return Data(out.prefix(Int(length)))
    }

    // MARK: Helpers

    private func python(_ root: URL, _ products: [String]) throws -> Set<Int> {
        let out = try run("/usr/bin/python3", [Self.repo.appending(path: "apps/client/casc_archives.py").path, root.path] + products)
        return Set(out.split(whereSeparator: \.isNewline).compactMap { Int($0) })
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String]) throws -> String {
        let result = try TestShell.run(exe, args)
        XCTAssertEqual(result.status, 0, "\(exe) \(args.joined(separator: " "))")
        return result.text
    }
}
