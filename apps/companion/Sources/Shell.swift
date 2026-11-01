import Foundation

/// A finished command's output.
struct CommandResult {
    var status: Int32
    var stdout: Data
    var stderr: String
    var text: String { String(decoding: stdout, as: UTF8.self) }
}

struct CommandFailed: LocalizedError {
    var command: String
    var result: CommandResult
    /// One line: devicectl's stderr spreads an error over indented lines ("ERROR: The operation couldn’t
    /// be completed. (CoreDevice.ActionError error 3.)\n    NSDebugDescription = <what went wrong>"),
    /// and the NSDebugDescription is the part that says something.
    var errorDescription: String? {
        let stderr = result.stderr
        let message = stderr.firstMatch(of: /NSDebugDescription = ([^\n]+)/).map { String($0.1) } ?? stderr
        let line = message.split(whereSeparator: \.isWhitespace).joined(separator: " ").suffix(400)
        return "\(command) exited with status \(result.status)" + (line.isEmpty ? "" : ": \(line)")
    }
}

/// An error with a message for the window.
struct Failure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Shell {
    /// Runs `exe args` to completion. Cancelling the task terminates it.
    @discardableResult
    static func run(_ exe: String, _ args: [String], env: [String: String] = [:],
                    check: Bool = true) async throws -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        // terminationHandler, not waitUntilExit: called on a dispatch thread, which has no run loop going,
        // waitUntilExit can miss the exit and wait forever.
        let exited = DispatchGroup()
        exited.enter()
        p.terminationHandler = { _ in exited.leave() }
        try p.run()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<CommandResult, Never>) in
                DispatchQueue.global().async {
                    // Both pipes are drained at once, so neither fills up and stalls the command.
                    var errData = Data()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        errData = err.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    let outData = out.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    exited.wait()
                    c.resume(returning: CommandResult(status: p.terminationStatus, stdout: outData,
                                                      stderr: String(decoding: errData, as: UTF8.self)))
                }
            }
        } onCancel: {
            p.terminate()
        }
        try Task.checkCancellation()
        if check && result.status != 0 {
            let name = ([(exe as NSString).lastPathComponent] + args.prefix(3)).joined(separator: " ")
            throw CommandFailed(command: name, result: result)
        }
        return result
    }
}

/// A long-running command whose output (stdout and stderr together) arrives line by line, on a
/// background queue.
final class StreamingCommand: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private var partial = Data()
    private let exited = DispatchGroup()
    /// Left at the output's end, which can come after the exit.
    private let drained = DispatchGroup()

    init(_ exe: String, _ args: [String], env: [String: String] = [:], onLine: @escaping (String) -> Void) {
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        if !env.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        exited.enter()
        drained.enter()
        process.terminationHandler = { [exited] _ in exited.leave() }
        // Holds self until the output ends (clearing the handler lets go), so it's safe to drop the
        // command once it has exited.
        pipe.fileHandleForReading.readabilityHandler = { [self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                if !self.partial.isEmpty { onLine(String(decoding: self.partial, as: UTF8.self)) }
                self.partial.removeAll()
                self.drained.leave()
                return
            }
            self.partial.append(data)
            while let nl = self.partial.firstIndex(of: UInt8(ascii: "\n")) {
                onLine(String(decoding: self.partial[self.partial.startIndex..<nl], as: UTF8.self))
                self.partial.removeSubrange(self.partial.startIndex...nl)
            }
        }
    }

    func start() throws { try process.run() }

    var isRunning: Bool { process.isRunning }

    func terminate() { if process.isRunning { process.terminate() } }

    /// Waits for the command to exit and its output to end (every line delivered), and returns its status.
    /// A child that keeps the output open after the command exits is waited on for 2 s at most.
    func wait() async -> Int32 {
        await withCheckedContinuation { c in
            exited.notify(queue: .global()) {
                _ = self.drained.wait(timeout: .now() + 2)
                c.resume(returning: self.process.terminationStatus)
            }
        }
    }
}

/// A thread-safe flag, set from a command's output handler.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    var value: Bool { lock.withLock { set } }
    func raise() { lock.withLock { set = true } }
}

/// A value shared with a command's output handler.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A log file under ~/Library/Logs/Slashplayed/, each line prefixed with seconds since `t0` (like run.sh's).
final class LogFile: @unchecked Sendable {
    private let handle: FileHandle?
    private let t0: Date
    private let lock = NSLock()

    init(_ url: URL, t0: Date) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        self.t0 = t0
    }

    func write(_ line: String) {
        let stamped = String(format: "%7.2f ", Date().timeIntervalSince(t0)) + line + "\n"
        lock.withLock { handle?.write(Data(stamped.utf8)) }
    }

    deinit { try? handle?.close() }
}
