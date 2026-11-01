import Foundation

/// Fetches what it takes to triage a play session from the device, as apps/client/pull-logs.sh does
/// (keep the two in step), and sums it up:
///   - Documents/spconsole*.log: the shims' console, the last 5 launches (spconsole.log is the latest),
///     each line stamped with the local time. stats: lines every 30 s, lifecycle: lines as they happen.
///   - Documents/<flavor folder>/Logs and Errors: the client's own logs and error reports, for each of
///     the device's games.
///   - The system's crash, jetsam and resource reports that mention the app.
/// Into ~/Library/Logs/Slashplayed/triage/<date-time>/ (app/ and system/ as on the device, summary.txt).
/// Needs the device reachable; the headset awake.
///
/// Each file is its own devicectl call, about 0.6 s over USB and more over Wi-Fi (the rc6 run: 74 files,
/// 90 s, for a few MB). So `parallel` run at once (28 crash reports from the iPhone over Wi-Fi: 22 s one
/// by one, 9.5 s six at a time), and onProgress says how many are done.
enum DeviceLogs {
    static let parallel = 6

    struct Pulled {
        var dir: URL
        /// Device paths copied, and those that failed (listed, but the copy didn't come).
        var fetched: [String] = []
        var failed: [String] = []
        var summary = ""
    }

    static func pull(from device: Device, flavors: [Flavor],
                     onProgress: @MainActor @escaping (_ done: Int, _ total: Int) -> Void = { _, _ in }) async throws -> Pulled {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let dir = Paths.logs.appending(path: "triage/\(stamp.string(from: Date()))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var pulled = Pulled(dir: dir)

        // One listing of Documents, which devicectl gives in full (subfolders too), not one per game's Logs
        // and Errors: a folder that isn't there yet (a game not run yet) fails just as a dropped connection
        // does, so it was tried three times, 3 s apart, about 6 s a folder (the rc6 run's slow pulls). A
        // listing that fails leaves the app's part out, as pull-logs.sh.
        let listing = (try? await device.files(in: "Documents", recursive: true)) ?? [:]
        let folders = flavors.flatMap { ["\($0.folder)/Logs/", "\($0.folder)/Errors/"] }
        let app = listing.keys.filter { path in
            path.wholeMatch(of: /spconsole[.0-9]*log/) != nil || folders.contains { path.hasPrefix($0) }
        }.map { "Documents/\($0)" }
        let system = (try? await device.files(in: nil, recursive: true, domain: .crashLogs))?.keys
            .filter { $0.range(of: #"wow|slashplayed|jetsam|exc_?resource"#, options: [.regularExpression, .caseInsensitive]) != nil } ?? []

        let jobs = app.sorted().map { ($0, Device.Domain.app, "app") } + system.sorted().map { ($0, Device.Domain.crashLogs, "system") }
        for (path, _, local) in jobs {
            try FileManager.default.createDirectory(at: dir.appending(path: "\(local)/\(path)").deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        await onProgress(0, jobs.count)
        // A copy now and then fails once (a different file each run); the next try works.
        let fetch = { @Sendable (job: (String, Device.Domain, String)) async throws -> (String, Bool) in
            let (path, domain, local) = job
            do {
                try await Device.retrying { try await device.fetch(path, to: dir.appending(path: "\(local)/\(path)"), from: domain) }
                return (path, true)
            } catch let e as CancellationError {
                throw e
            } catch {
                return (path, false)
            }
        }
        try await withThrowingTaskGroup(of: (String, Bool).self) { group in
            var next = jobs.makeIterator(), done = 0
            for _ in 0..<parallel { if let job = next.next() { group.addTask { try await fetch(job) } } }
            while let (path, ok) = try await group.next() {
                if ok { pulled.fetched.append(path) } else { pulled.failed.append(path) }
                done += 1
                await onProgress(done, jobs.count)
                if let job = next.next() { group.addTask { try await fetch(job) } }
            }
        }
        pulled.fetched.sort()
        pulled.failed.sort()

        var summary = ["\(device.name), pulled \(SetupStatus.count(pulled.fetched.count, "file"))" +
                       (pulled.failed.isEmpty ? "" : " (\(pulled.failed.count) failed: \(pulled.failed.joined(separator: ", ")))")]
        let documents = dir.appending(path: "app/Documents")
        for name in ["spconsole.log"] + (1...5).map({ "spconsole.\($0).log" }) {
            guard let text = try? String(contentsOf: documents.appending(path: name), encoding: .utf8) else { continue }
            summary.append("")
            summary.append(summarize(text, name: name))
        }
        summary += system.filter(pulled.fetched.contains).sorted().map { "system report: \($0)" }
        summary += app.filter { $0.contains("/Errors/") && pulled.fetched.contains($0) }.sorted().map { "client error report: \($0)" }
        pulled.summary = summary.joined(separator: "\n")
        try (pulled.summary + "\n").write(to: dir.appending(path: "summary.txt"), atomically: true, encoding: .utf8)
        return pulled
    }

    /// One console log's summary: when it spans, the stats lines' fps (average and the lowest 30 s window),
    /// worst frame, slow frames, memory footprint peak and least left, thermal states; then the notable
    /// events (lifecycle, memory warnings, crashes, a stalled run loop) and the last lines.
    static func summarize(_ text: String, name: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.isEmpty }
        let time = { (line: String?) in line.map { String($0.prefix(8)) } ?? "?" }
        var out = ["== \(name): \(time(lines.first)) to \(time(lines.last))"]

        let stats = lines.filter { $0.contains("stats: ") }
        let fps = stats.compactMap { l in l.firstMatch(of: /([0-9.]+) fps/).flatMap { Double($0.1) } }
        if fps.isEmpty {
            out.append("  no stats lines")
        } else {
            let worstFrame = stats.compactMap { l in l.firstMatch(of: /worst (\d+) ms/).flatMap { Int($0.1) } }.max() ?? 0
            let slow = stats.compactMap { l in l.firstMatch(of: /(\d+) over 50 ms/).flatMap { Int($0.1) } }.reduce(0, +)
            let peak = stats.compactMap { l in l.firstMatch(of: /peak (\d+)/).flatMap { Int($0.1) } }.max() ?? 0
            let left = stats.compactMap { l in l.firstMatch(of: /(\d+) MB left/).flatMap { Int($0.1) } }.min() ?? 0
            let thermal = Set(stats.compactMap { l in l.firstMatch(of: /thermal (\w+)/).map { String($0.1) } }).sorted()
            out.append(String(format: "  %d stats lines: %.1f fps average, %.1f lowest 30 s, worst frame %d ms, %d frames over 50 ms",
                              stats.count, fps.reduce(0, +) / Double(fps.count), fps.min()!, worstFrame, slow))
            out.append("  footprint peak \(peak) MB, least left \(left) MB, thermal \(thermal.joined(separator: "/"))")
        }
        let events = lines.filter {
            $0.range(of: #"lifecycle: |MEMORY|crash: |FAULT|hasn.t pumped|objc exception|Fatal|signal"#, options: .regularExpression) != nil
        }
        out.append("  events:")
        out += events.suffix(40).map { "    " + $0.prefix(160) }
        out.append("  last lines:")
        out += lines.suffix(5).map { "    " + $0.prefix(160) }
        return out.joined(separator: "\n")
    }
}
