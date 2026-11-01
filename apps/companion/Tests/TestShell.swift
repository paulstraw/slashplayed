import Foundation

/// The tests' commands (openssl, security, clang, lipo, codesign, ditto, ...), run to completion
/// synchronously, as class setUps and sync helpers need: Shell.run's way of waiting without its async.
///
/// Never Process.waitUntilExit: it polls the run loop and on this macOS adds ~65 ms to every command
/// (/usr/bin/true: 0.067 s against 0.002 s with a terminationHandler), and the tests run well over a
/// hundred of them, ~10 s in all.
enum TestShell {
    /// Runs `exe args` in `directory` (the test process's own when nil). stdout is returned; stderr with it
    /// when `mergingStderr`, otherwise it goes to the test log. No input, so nothing can wait on a prompt.
    static func run(_ exe: String, _ args: [String], in directory: URL? = nil,
                    mergingStderr: Bool = false) throws -> CommandResult {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let directory { p.currentDirectoryURL = directory }
        p.standardOutput = out
        if mergingStderr { p.standardError = out }
        p.standardInput = FileHandle.nullDevice
        // Set before run(), so a command that exits at once can't signal before anyone is listening.
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        try p.run()
        // The output to its end first: a command that fills the pipe would never exit otherwise.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        return CommandResult(status: p.terminationStatus, stdout: data, stderr: "")
    }

    /// `run`, failing on a nonzero status with the command's output (both streams, when merged) in the
    /// error. Returns the output's text.
    @discardableResult
    static func check(_ exe: String, _ args: [String], in directory: URL? = nil,
                      mergingStderr: Bool = false) throws -> String {
        let result = try run(exe, args, in: directory, mergingStderr: mergingStderr)
        guard result.status == 0 else {
            let name = ([(exe as NSString).lastPathComponent] + args.prefix(2)).joined(separator: " ")
            throw Failure("\(name) failed with status \(result.status): \(result.text)")
        }
        return result.text
    }
}
