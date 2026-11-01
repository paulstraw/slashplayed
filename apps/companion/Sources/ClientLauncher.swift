import Foundation

/// Runs the client on the device, as apps/client/run.sh does (keep the two in step): launches it with its
/// output on devicectl's console and follows its launcher (apps/client/launcher.m, spjit.m) as the
/// on-device JIT helper attaches, the shim's prepare stop is serviced, and the helper detaches. Nothing on
/// the Mac debugs the client. When the helper can't do its part, the launcher says why, on the device's
/// screen and on the console, and that's the failure shown here. devicectl sometimes fails to attach the
/// console while the app still starts; then the client is relaunched, up to 3 attempts (a launch spends
/// nothing: the token is only used at login). Logs go to ~/Library/Logs/Slashplayed/console.txt (failed
/// attempts: console-failN.txt).
@MainActor
final class ClientLauncher {
    enum Phase {
        case starting(attempt: Int)
        /// The headset has no pairing record and shows its pairing screen (sppair.m): it waits on the person.
        case pairing
        /// LocalDevVPN is off on the device, which waits for it on a screen of its own (spvpn.m).
        case waitingForVPN
        /// The patch service has a newer build than the device's image, and the device says so (sppatch.m)
        /// until the person presses Play Anyway or Update.
        case newerBuild(Flavor)
        case preparing
    }

    static let attempts = 3
    /// How long the launch may take to the end of the prepare: the helper mounting the developer disk
    /// image (personalized by Apple's server) is the slow case; a launch with it mounted takes ~2 s. The
    /// headset's pairing screen, the wait for LocalDevVPN, and the newer-build screen wait on a person, so
    /// they don't count: the time starts again after them.
    static let prepareTimeout: TimeInterval = 180

    /// The launcher's console lines this follows (apps/client/launcher.m, spjit.m, sppatch.m,
    /// shims/system/spsystem.c).
    enum Marker {
        static let attached = "[sp:launch] jit: helper attached"
        static let alreadyTraced = "[sp:launch] jit: a debugger is already attached"
        static let problem = "[sp:launch] can't prepare the client: "
        static let detached = "[sp:System] detached"
        static let pairing = "[sp:launch] pair: showing the pairing screen"
        static let paired = "[sp:launch] pair: wrote Library/sppairing.plist"
        static let vpnOff = "[sp:launch] vpn: waiting for LocalDevVPN"
        static let vpnOn = "[sp:launch] vpn: LocalDevVPN is on"
        static let newerBuild = "[sp:launch] patch: showing the newer-build screen"
        static let playAnyway = "[sp:launch] patch: Play Anyway"
        /// The person chose Update: the device makes the new image itself (sppatch.m) and the launch goes on.
        static let update = "[sp:launch] patch: Update"
        /// An alert the client asked for, which the AppKit shim logs and shows nobody (shims/appkit/spnotice.m).
        static let alert = "CFUserNotificationCreate: \""
    }

    var onPhase: (Phase) -> Void = { _ in }
    /// Called on the main queue for each line of console output.
    var onLog: (String) -> Void = { _ in }
    /// Runs before a launch made again after a drop: Pipeline waits there for the device's unlock.
    var beforeRelaunch: () async throws -> Void = {}

    private var console: StreamingCommand?
    private(set) var pid: Int?
    private var device: Device?
    private let exit = Locked<Int?>(nil)
    /// The client's exit code, from devicectl's console ("The app terminated with the exit code 1.").
    var exitCode: Int? { exit.value }
    private let alert = Locked<String?>(nil)
    /// The message of the last alert the client asked for: the client shows its error that way before it
    /// quits, and with no alert server on the device nobody saw it (ERROR #137, the rc9 run).
    var lastAlert: String? { alert.value }

    /// Launches the client and returns once the helper has prepared it and detached.
    func launch(_ flavor: Flavor, on device: Device, arguments: [String]) async throws {
        self.device = device
        let logs = Paths.logs
        let t0 = Date()
        for n in 1...Self.attempts { try? FileManager.default.removeItem(at: logs.appending(path: "console-fail\(n).txt")) }

        for attempt in 1...Self.attempts {
            try Task.checkCancellation()
            onPhase(.starting(attempt: attempt))
            let consoleLog = LogFile(logs.appending(path: "console.txt"), t0: t0)
            let attached = Flag(), detached = Flag(), noSocket = Flag(), pairing = Flag(), paired = Flag()
            let newerBuild = Flag(), playAnyway = Flag()
            // Counts, not flags: the device can wait for LocalDevVPN more than once in a launch.
            let vpnOff = Locked(0), vpnOn = Locked(0)
            let problem = Locked<String?>(nil), lastError = Locked<String?>(nil)
            // devicectl's own failure, from its first ERROR: line on (the client's lines come before it).
            let errorText = Locked("")
            let exit = self.exit, alert = self.alert
            exit.value = nil
            alert.value = nil
            let console = StreamingCommand(
                Device.xcrun,
                ["devicectl", "device", "process", "launch", "--device", device.udid, "--terminate-existing",
                 "--console", "--", Device.bundleID] + arguments,
                env: env(flavor)
            ) { [weak self] line in
                consoleLog.write(line)
                if line.contains(Marker.attached) || line.contains(Marker.alreadyTraced) { attached.raise() }
                if line.contains(Marker.detached) { detached.raise() }
                if line.contains(Marker.pairing) { pairing.raise() }
                if line.contains(Marker.paired) { paired.raise() }
                if line.contains(Marker.vpnOff) { vpnOff.value += 1 }
                if line.contains(Marker.vpnOn) { vpnOn.value += 1 }
                if line.contains(Marker.newerBuild) { newerBuild.raise() }
                if line.contains(Marker.playAnyway) || line.contains(Marker.update) { playAnyway.raise() }
                if let r = line.range(of: Marker.problem) { problem.value = String(line[r.upperBound...]) }
                if line.contains("Failed to read socket ID") { noSocket.raise() }
                if line.contains("NSDebugDescription") || line.contains("ERROR:") {
                    lastError.value = line.trimmingCharacters(in: .whitespaces)
                }
                if line.contains("ERROR:") || !errorText.value.isEmpty { errorText.value += line + "\n" }
                if let m = line.firstMatch(of: try! Regex("terminated with the exit code (-?[0-9]+)", as: (Substring, Substring).self)) { exit.value = Int(m.1) }
                if line.contains(Marker.alert), let message = ClientStop.alert(in: line) { alert.value = message }
                DispatchQueue.main.async { self?.onLog(line) }
            }
            self.console = console
            try console.start()

            var preparing = false, waitingOnPerson = false, waitingOnVPN = false, waitingOnPatch = false
            var dropped = false
            var deadline = Date(timeIntervalSinceNow: Self.prepareTimeout)
            while !detached.value && !noSocket.value {
                if Task.isCancelled {
                    await stop()
                    throw CancellationError()
                }
                if let problem = problem.value {
                    // The device shows the same message; it stays up until the person leaves the app.
                    console.terminate()
                    self.console = nil
                    throw Failure(problem)
                }
                if pairing.value && !paired.value {
                    if !waitingOnPerson { onPhase(.pairing) }
                    waitingOnPerson = true
                    deadline = Date(timeIntervalSinceNow: Self.prepareTimeout)
                }
                // The newer-build screen comes first (before the sign-in and the helper), once a launch.
                if newerBuild.value && !playAnyway.value {
                    if !waitingOnPatch { onPhase(.newerBuild(flavor)) }
                    waitingOnPatch = true
                    deadline = Date(timeIntervalSinceNow: Self.prepareTimeout)
                } else if waitingOnPatch {
                    waitingOnPatch = false
                    deadline = Date(timeIntervalSinceNow: Self.prepareTimeout)
                    onPhase(.starting(attempt: attempt))
                }
                let vpnWait = vpnOff.value > vpnOn.value
                if vpnWait {
                    if !waitingOnVPN { onPhase(.waitingForVPN) }
                    deadline = Date(timeIntervalSinceNow: Self.prepareTimeout)
                } else if waitingOnVPN {
                    // Back to whatever it was doing: pairing or starting.
                    onPhase(pairing.value && !paired.value ? .pairing : .starting(attempt: attempt))
                    waitingOnPerson = pairing.value && !paired.value
                }
                waitingOnVPN = vpnWait
                if attached.value && !preparing {
                    preparing = true
                    onPhase(.preparing)
                }
                if !console.isRunning {
                    self.console = nil
                    // The tunnel to a device over Wi-Fi dropped before the client was attached (Device.dropSigns):
                    // nothing ran yet, so the launch is made again once a new tunnel is up.
                    if !attached.value, Device.connectionDropped(text: errorText.value) {
                        dropped = true
                        break
                    }
                    let why = lastError.value.map { " devicectl: \($0)" } ?? ""
                    switch device.kind {
                    case .headset:
                        throw Failure("The client didn't start on the headset. If the headset was taken off, put it on, then press Retry Launch.\(why)")
                    case .iPad, .iPhone:
                        throw Failure("The client didn't start on the \(device.noun). Unlock it, then press Retry Launch.\(why)")
                    }
                }
                if Date() > deadline {
                    await stop()
                    // visionOS holds a launch on a locked headset until it's put on (Device.Lock), with nothing
                    // on the console; say that, not the prepare (rc16's run).
                    if !attached.value, await device.lock() == .locked {
                        switch device.kind {
                        case .headset:
                            throw Failure("The client didn't start because the headset is locked. Put it on, then press Retry Launch.")
                        case .iPad, .iPhone:
                            throw Failure("The client didn't start because the \(device.noun) is locked. Unlock it, then press Retry Launch.")
                        }
                    }
                    throw Failure("The client's code wasn't prepared within \(Int(Self.prepareTimeout)) s. The log has its last messages (~/Library/Logs/Slashplayed/console.txt).")
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            pid = try? await device.clientPID()
            if detached.value {
                log("prepared\(pid.map { ", pid \($0)" } ?? "")")
                return
            }

            if dropped {
                guard attempt < Self.attempts else { throw device.connectionDroppedProblem(during: "the launch") }
                log("the connection to the \(device.noun) dropped during the launch; trying again (\(attempt + 1) of \(Self.attempts))")
                try? FileManager.default.moveItem(at: logs.appending(path: "console.txt"),
                                                  to: logs.appending(path: "console-fail\(attempt).txt"))
                try await Task.sleep(for: Device.dropWait)
                try await beforeRelaunch()
                continue
            }

            // The console never attached, so nothing can be followed: relaunch.
            log("devicectl didn't attach the console (attempt \(attempt) of \(Self.attempts))")
            await stop()
            try? await Task.sleep(for: .seconds(2))
            _ = await console.wait()
            self.console = nil
            self.pid = nil
            try? FileManager.default.moveItem(at: logs.appending(path: "console.txt"),
                                              to: logs.appending(path: "console-fail\(attempt).txt"))
        }
        throw Failure("devicectl couldn't attach to the client's console \(Self.attempts) times. Logs are in ~/Library/Logs/Slashplayed/.")
    }

    private func env(_ flavor: Flavor) -> [String: String] {
        var env = ["DEVICECTL_CHILD_SP_LAUNCH_FLAVOR": flavor.rawValue]
        // Pre-release companions only (BindCheck.deviceDrill).
        if let drill = BindCheck.deviceDrill {
            log("patch drill on the device: SP_PATCH_DRILL=\(drill)")
            env["DEVICECTL_CHILD_SP_PATCH_DRILL"] = drill
        }
        // -skip-intro (agent and dev runs): no intro movie or Screen Narrator question (launcher.m skip_intro).
        // Only from the command line, which no person's Play has, so people still see both.
        if CommandLine.arguments.contains("-skip-intro") {
            log("skip intro on the device: SP_SKIP_INTRO=1")
            env["DEVICECTL_CHILD_SP_SKIP_INTRO"] = "1"
        }
        return env
    }

    /// Waits for the running client to exit (its console closes).
    func waitForExit() async -> Int32 {
        guard let console else { return 0 }
        let status = await console.wait()
        self.console = nil
        pid = nil
        return status
    }

    /// Kills the client and its console.
    func stop() async {
        if pid == nil, let device { pid = try? await device.clientPID() }
        if let pid, let device { await device.kill(pid: pid) }
        console?.terminate()
    }

    private func log(_ line: String) { onLog("[companion] \(line)") }
}
