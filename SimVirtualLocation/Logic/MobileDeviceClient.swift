//
//  MobileDeviceClient.swift
//  SimVirtualLocation
//
//  Single abstraction for all pymobiledevice3 access.
//  - iOS 16-: Transport.legacy(udid:) -> uses pymobiledevice3 developer simulate-location
//             with --udid; no tunnel, no root.
//  - iOS 17+: Transport.rsd(udid:) -> requires a running `pymobiledevice3 remote tunneld`
//             daemon. ensureTunneldRunning() launches it once (osascript admin) per Mac boot.
//             Subsequent commands use --udid only; tunneld auto-discovers the tunnel.
//
//  Owners and ownership:
//  - LocationController owns a single MobileDeviceClient instance.
//  - GPXPlayback (existing wrapper) is reworked to take a GPXPlaybackHandle from here.
//

import Foundation
import AppKit
import CoreLocation
import Combine

@MainActor
final class MobileDeviceClient: ObservableObject {

    // MARK: - Public Types

    enum TunneldStatus: Equatable {
        case idle
        case authorizing
        case launching
        case ready
        case failed(String)   // message only, for Equatable conformance
    }

    enum Transport: Equatable {
        case legacy(udid: String)
        case rsd(udid: String)

        var udid: String {
            switch self {
            case .legacy(let u), .rsd(let u): return u
            }
        }

        var label: String {
            switch self {
            case .legacy: return "legacy"
            case .rsd:    return "rsd"
            }
        }
    }

    enum MountResult { case mounted, alreadyMounted }

    // MARK: - Public State

    @Published private(set) var tunneldStatus: TunneldStatus = .idle

    // MARK: - Private Properties

    private let processRunner = ProcessRunner()
    private let logger = AppLogger.shared

    /// Summary of the last device list logged at info level; the 30 s health
    /// check calls listDevices() constantly, so repeats drop to debug.
    private var lastLoggedDeviceSummary: String?

    /// Currently running long-lived process (GPX play). At most one.
    private var currentLongRunning: ProcessRunner.LongRunningHandle?

    /// Last time tunneld's HTTP endpoint was confirmed reachable. `.ready` is
    /// a cache — tunneld can die behind our back, so ensureTunneldRunning()
    /// re-probes at most once per `tunneldProbeInterval`.
    private var lastTunneldProbe: Date = .distantPast
    private static let tunneldProbeInterval: TimeInterval = 10

    // MARK: - Init

    init() {}

    // MARK: - Device discovery

    func listDevices() async throws -> [Device] {
        let result = try await processRunner.run(args: ["--no-color", "usbmux", "list"], timeout: 15)
        if result.exitCode != 0 {
            throw AppError.from(stderr: result.stderr, context: .listDevices)
        }
        let devices = try JSONDecoder().decode([Device].self, from: result.stdout)
        var seen: Set<String> = []
        let unique = devices.filter { seen.insert($0.id).inserted && $0.isUSB }
        let summary = unique.map { "\($0.name) (\($0.version))" }.joined(separator: ", ")
        if summary != lastLoggedDeviceSummary {
            lastLoggedDeviceSummary = summary
            logger.info("Connected USB devices: \(summary)")
        } else {
            logger.debug("Connected USB devices unchanged")
        }
        return unique
    }

    // MARK: - Developer Mode

    func checkDeveloperMode(udid: String) async throws -> Bool {
        let result = try await processRunner.run(args: ["amfi", "developer-mode-status", "--udid", udid], timeout: 15)
        if result.exitCode != 0 {
            throw AppError.from(stderr: result.stderr, context: .checkDeveloperMode)
        }
        let text = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        logger.info("Developer Mode status: \(text)")
        return text.contains("true")
    }

    func revealDeveloperMode(udid: String) async throws {
        logger.info("Prompting device to open Developer Mode menu")
        _ = try await processRunner.run(args: ["amfi", "reveal-developer-mode", "--udid", udid], timeout: 15)
        // reveal-developer-mode is best-effort; ignore exit code.
    }

    // MARK: - Mount Developer Image

    func mountDeveloperImage(udid: String) async throws -> MountResult {
        let result = try await processRunner.run(args: ["mounter", "auto-mount", "--udid", udid], timeout: 300)

        // pymobiledevice3 prints "already mounted" on stderr with non-zero exit;
        // treat that as success.
        if result.exitCode == 0 {
            return .mounted
        }
        let classified = AppError.from(stderr: result.stderr, context: .mount)
        if case .alreadyMounted = classified {
            logger.info("Developer Image already mounted on device")
            return .alreadyMounted
        }
        throw classified
    }

    // MARK: - Location commands

    func setLocation(_ coord: CLLocationCoordinate2D, transport: Transport) async throws {
        if case .rsd = transport {
            try await ensureTunneldRunning()
        }
        let args = locationSetArgs(coord, transport: transport)
        let result = try await processRunner.run(args: args, timeout: 15)
        try classifyResult(result, context: .setLocation)
    }

    func clearLocation(transport: Transport) async throws {
        if case .rsd = transport {
            try await ensureTunneldRunning()
        }
        let args = locationClearArgs(transport)
        let result = try await processRunner.run(args: args, timeout: 15)
        try classifyResult(result, context: .clearLocation)
    }

    /// Plays GPX in the background. Returns a handle the caller stores.
    /// Calling stop() on the handle SIGTERMs the underlying process.
    func playGPX(
        _ url: URL,
        transport: Transport,
        onTermination: ((Int32) -> Void)? = nil
    ) async throws -> ProcessRunner.LongRunningHandle {
        if case .rsd = transport {
            try await ensureTunneldRunning()
        }
        // Stop any previously running long-running task first.
        await currentLongRunning?.stop()
        currentLongRunning = nil

        let args = locationPlayArgs(url, transport: transport)
        let handle = try processRunner.runDiscardingOutput(args: args, onTermination: onTermination)
        currentLongRunning = handle
        logger.info("Started GPX playback: \(url.lastPathComponent), transport=\(transport.label)")
        return handle
    }

    // MARK: - Argument builders

    private func locationSetArgs(_ c: CLLocationCoordinate2D, transport: Transport) -> [String] {
        let lat = String(format: "%.5f", c.latitude)
        let lng = String(format: "%.5f", c.longitude)
        switch transport {
        case .legacy(let udid):
            return ["developer", "simulate-location", "set",
                    "--udid", udid, "--", lat, lng]
        case .rsd(let udid):
            return ["developer", "dvt", "simulate-location", "set",
                    "--udid", udid, "--", lat, lng]
        }
    }

    private func locationClearArgs(_ transport: Transport) -> [String] {
        switch transport {
        case .legacy(let udid):
            return ["developer", "simulate-location", "clear", "--udid", udid]
        case .rsd(let udid):
            return ["developer", "dvt", "simulate-location", "clear", "--udid", udid]
        }
    }

    private func locationPlayArgs(_ url: URL, transport: Transport) -> [String] {
        switch transport {
        case .legacy(let udid):
            return ["developer", "dvt", "simulate-location", "play",
                    "--udid", udid, url.path]
        case .rsd(let udid):
            return ["developer", "dvt", "simulate-location", "play",
                    "--udid", udid, url.path]
        }
    }

    private func classifyResult(_ result: ProcessRunner.ProcessResult,
                                context: AppError.Context) throws {
        // SIGTERM (15) is expected for our own teardown — not an error.
        if result.exitCode == 0 || result.exitCode == 15 { return }
        let classified = AppError.from(stderr: result.stderr, context: context)
        if case .harmlessWarning = classified { return }
        throw classified
    }

    // MARK: - Tunneld lifecycle

    private let tunneldHostURL = URL(string: "http://127.0.0.1:49151/")!

    func ensureTunneldRunning(allowLaunch: Bool = false) async throws {
        if case .ready = tunneldStatus {
            if Date().timeIntervalSince(lastTunneldProbe) < Self.tunneldProbeInterval {
                return
            }
            if await TunneldSupervisor.isReachable(url: tunneldHostURL) {
                lastTunneldProbe = Date()
                return
            }
            // tunneld died behind the cached .ready. Never relaunch from an
            // inline command path — sudo prompts belong to the explicit
            // Connect flow and the recovery ladder (single-flight, one
            // prompt max).
            logger.warn("tunneld no longer reachable")
            tunneldStatus = .idle
            if !allowLaunch { throw AppError.tunneldNotReady }
        }

        if await TunneldSupervisor.isRunning() {
            logger.info("tunneld already running, polling for HTTP readiness")
            tunneldStatus = .launching
            try await TunneldSupervisor.waitForReady(url: tunneldHostURL, timeout: 30.0)
            lastTunneldProbe = Date()
            tunneldStatus = .ready
            logger.info("tunneld is ready")
            return
        }

        guard allowLaunch else { throw AppError.tunneldNotReady }

        // Need root authorization to launch.
        tunneldStatus = .authorizing
        do {
            try await TunneldSupervisor.launchAsRoot()
        } catch let err as AppError {
            tunneldStatus = .failed(err.userMessage)
            throw err
        }

        tunneldStatus = .launching
        do {
            try await TunneldSupervisor.waitForReady(url: tunneldHostURL, timeout: 30.0)
        } catch {
            tunneldStatus = .failed("Not ready within 30s")
            throw AppError.tunneldNotReady
        }
        lastTunneldProbe = Date()
        tunneldStatus = .ready
        logger.info("tunneld launched and ready")
    }

    /// Kill all residual `simulate-location` processes (set, play, or otherwise).
    /// Must be called AFTER clearLocation has completed — the broad pattern would
    /// also match a running clearLocation process.
    func killResidualSimulationProcesses() async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "simulate-location"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    /// Manual-only. Not wired to any default UI affordance.
    func killTunneld() async throws {
        try await TunneldSupervisor.kill()
        tunneldStatus = .idle
    }

    // MARK: - Tunnel recovery primitives

    /// True when tunneld currently advertises a live tunnel for `udid`.
    /// A 200 from tunneld is not enough — the daemon stays up even after a
    /// specific device's tunnel drops, so we parse its JSON and look for the
    /// UDID key explicitly.
    func verifyTunnel(udid: String) async -> Bool {
        let udids = await TunneldSupervisor.tunneledUDIDs(url: tunneldHostURL)
        return udids.contains { $0.caseInsensitiveCompare(udid) == .orderedSame }
    }

    /// Whether the `remote tunneld` process is alive at all.
    func tunneldProcessAlive() async -> Bool {
        await TunneldSupervisor.isRunning()
    }

    /// Kills any existing tunneld and relaunches it as root in a single sudo
    /// prompt, then waits for HTTP readiness. Used as the last rung of tunnel
    /// recovery when a stuck or dead daemon is the only remaining explanation.
    func forceRestartTunneld() async throws {
        tunneldStatus = .authorizing
        try await TunneldSupervisor.forceRestart()
        tunneldStatus = .launching
        do {
            try await TunneldSupervisor.waitForReady(url: tunneldHostURL, timeout: 30.0)
        } catch {
            tunneldStatus = .failed("Not ready within 30s")
            throw AppError.tunneldNotReady
        }
        lastTunneldProbe = Date()
        tunneldStatus = .ready
    }
}

// MARK: - ProcessRunner

/// Internal helper: wraps Process for one-shot and long-running pymobiledevice3 calls.
/// All path resolution and error mapping lives here so MobileDeviceClient methods
/// stay declarative.
struct ProcessRunner {

    struct ProcessResult {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
    }

    final class LongRunningHandle {
        let task: Process

        /// Set at the top of stop() — before any signalling — so a termination
        /// callback that fires during teardown can tell a deliberate stop from
        /// an unexpected death. Written and read on the main actor only.
        private(set) var wasStoppedIntentionally = false

        init(_ task: Process) { self.task = task }

        var isRunning: Bool { task.isRunning }

        // pymobiledevice3 is a Python wrapper that may spawn subprocesses
        // (asyncio workers, tunnel I/O helpers). Signalling only the parent
        // can leave the play loop running, so we walk the descendant tree.
        func stop() async {
            wasStoppedIntentionally = true
            guard task.isRunning else { return }
            let pid = task.processIdentifier

            // Collect descendants BEFORE the parent dies — once it exits,
            // children get reparented to launchd and pgrep -P can no longer find them.
            let descendants = Self.collectDescendants(of: pid)

            for child in descendants { kill(child, SIGTERM) }
            task.terminate()

            let start = Date()
            while task.isRunning && Date().timeIntervalSince(start) < 1.0 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }

            if task.isRunning {
                kill(pid, SIGKILL)
            }
            // SIGKILL anything that didn't honour SIGTERM (or that survived
            // because its parent died first and it got reparented).
            for child in descendants { kill(child, SIGKILL) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        private static func collectDescendants(of pid: pid_t) -> [pid_t] {
            var result: [pid_t] = []
            var stack: [pid_t] = [pid]
            while let current = stack.popLast() {
                let children = directChildren(of: current)
                result.append(contentsOf: children)
                stack.append(contentsOf: children)
            }
            return result
        }

        private static func directChildren(of pid: pid_t) -> [pid_t] {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            probe.arguments = ["-P", "\(pid)"]
            let pipe = Pipe()
            probe.standardOutput = pipe
            probe.standardError = Pipe()
            do {
                try probe.run()
                probe.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let text = String(data: data, encoding: .utf8) else { return [] }
                return text.split(separator: "\n").compactMap {
                    pid_t($0.trimmingCharacters(in: .whitespaces))
                }
            } catch {
                return []
            }
        }
    }

    // MARK: Lookup

    func locatePymobiledevice3() throws -> String {
        if let path = findExecutable("pymobiledevice3") { return path }
        throw AppError.pymobiledevice3NotInstalled
    }

    private func findExecutable(_ name: String) -> String? {
        let common = [
            "/Users/\(NSUserName())/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for p in common where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [
            "/Users/\(NSUserName())/.local/bin",
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/bin", "/bin",
            "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        task.environment = env
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let p = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (p?.isEmpty ?? true) ? nil : p
        } catch {
            return nil
        }
    }

    // MARK: One-shot

    /// Runs a one-shot pymobiledevice3 command.
    /// - The termination handler is installed BEFORE launch so a fast-exiting
    ///   process can never terminate before the handler exists (which would
    ///   leave the await hanging forever).
    /// - stdout/stderr are drained concurrently with the running process;
    ///   draining after exit deadlocks once output exceeds the 64 KB pipe buffer.
    /// - `timeout` bounds the wait; on expiry the process is SIGKILLed and
    ///   the call throws, so a hung command can't wedge its caller.
    func run(args: [String], timeout: TimeInterval = 30) async throws -> ProcessResult {
        let task = try makeTask(args: args)
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardInput = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        let (exitStream, exitContinuation) = AsyncStream.makeStream(of: Void.self)
        task.terminationHandler = { _ in
            exitContinuation.yield()
            exitContinuation.finish()
        }

        try task.run()

        let outTask = Task.detached { outPipe.fileHandleForReading.readDataToEndOfFile() }
        let errTask = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }

        let exited = await Self.waitForExit(exitStream, timeout: timeout)
        if !exited {
            kill(task.processIdentifier, SIGKILL)
            outTask.cancel()
            errTask.cancel()
            throw AppError.commandTimedOut(
                command: args.prefix(2).joined(separator: " "),
                seconds: Int(timeout)
            )
        }

        let out = await outTask.value
        let err = await errTask.value
        return ProcessResult(exitCode: task.terminationStatus, stdout: out, stderr: err)
    }

    /// Returns true if the process exited before `timeout`, false on expiry.
    private static func waitForExit(
        _ stream: AsyncStream<Void>,
        timeout: TimeInterval
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { break }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: Long-running (output discarded to avoid pipe buffer deadlock)

    func runDiscardingOutput(
        args: [String],
        onTermination: ((Int32) -> Void)? = nil
    ) throws -> LongRunningHandle {
        let task = try makeTask(args: args)
        let devNull = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = devNull
        task.standardError = devNull
        if let onTermination {
            task.terminationHandler = { proc in
                onTermination(proc.terminationStatus)
            }
        }
        try task.run()
        return LongRunningHandle(task)
    }

    // MARK: Helpers

    private func makeTask(args: [String]) throws -> Process {
        let path = try locatePymobiledevice3()
        let t = Process()
        t.executableURL = URL(fileURLWithPath: path)
        t.arguments = args
        return t
    }

}

// MARK: - TunneldSupervisor

/// Static utility around the `pymobiledevice3 remote tunneld` daemon.
/// Lifecycle policy (per design spec §4):
///  - Liveness: pgrep for `pymobiledevice3 remote tunneld`.
///  - Readiness: HTTP GET 127.0.0.1:49151 returns 2xx.
///  - Launch: NSAppleScript "do shell script ... with administrator privileges"
///    runs the command as root in the background; survives the App quitting.
///  - Kill: NSAppleScript with admin privileges (also prompts for password).
enum TunneldSupervisor {

    private static let logger = AppLogger.shared

    static func isRunning() async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                task.arguments = ["-f", "pymobiledevice3 remote tunneld"]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = Pipe()
                do {
                    try task.run()
                    task.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let pids = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(returning: !pids.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } catch {
                    cont.resume(returning: false)
                }
            }
        }
    }

    /// Polls `url` until it returns 2xx. Throws AppError.tunneldNotReady on timeout.
    static func waitForReady(url: URL, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let pollInterval: UInt64 = 500_000_000   // 500 ms

        while Date() < deadline {
            if await isReachable(url: url) { return }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
        throw AppError.tunneldNotReady
    }

    /// Fetches tunneld's tunnel table and returns the UDIDs that currently
    /// have a tunnel. tunneld responds with `{ "<udid>": [ { ... } ], ... }`.
    /// Returns [] on any error (daemon down, non-2xx, unparseable body).
    static func tunneledUDIDs(url: URL) async -> [String] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0
        req.httpMethod = "GET"
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [] }
            return Array(obj.keys)
        } catch {
            return []
        }
    }

    /// Kills any running tunneld and relaunches it, both inside a single
    /// administrator prompt. The script is written to a 0700 temp file so the
    /// pkill pattern's single quotes don't collide with osascript quoting.
    static func forceRestart() async throws {
        guard let pmPath = findPymobiledevice3Path() else {
            throw AppError.pymobiledevice3NotInstalled
        }
        let scriptPath = NSTemporaryDirectory() + "skywalker-restart-tunneld.sh"
        let body = """
        #!/bin/sh
        pkill -f 'pymobiledevice3 remote tunneld'
        sleep 1
        \(pmPath) remote tunneld > /tmp/skywalker-tunneld.log 2>&1 &
        """
        do {
            try body.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: scriptPath
            )
        } catch {
            throw AppError.tunneldFailedToStart(error.localizedDescription)
        }

        let script = "do shell script \"/bin/sh \(scriptPath)\" with administrator privileges"
        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        _ = appleScript?.executeAndReturnError(&errorDict)

        if let errorDict = errorDict {
            let msg = (errorDict[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
            if msg.contains("User canceled") {
                throw AppError.tunneldAuthorizationCancelled
            }
            throw AppError.tunneldAuthorizationFailed(msg)
        }
        logger.info("tunneld force-restarted as root")
    }

    static func isReachable(url: URL) async -> Bool {
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        req.httpMethod = "GET"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return true
            }
        } catch {
            // Connection refused / unreachable → not ready yet.
        }
        return false
    }

    /// Launches `pymobiledevice3 remote tunneld` as root in the background.
    /// One osascript prompt fires here.
    static func launchAsRoot() async throws {
        guard let pmPath = findPymobiledevice3Path() else {
            throw AppError.pymobiledevice3NotInstalled
        }
        // Background `&` so the AppleScript completes immediately; tunneld stays alive.
        let shell = "\(pmPath) remote tunneld > /tmp/skywalker-tunneld.log 2>&1 &"
        let script = "do shell script \"sh -c '\(shell)'\" with administrator privileges"

        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        _ = appleScript?.executeAndReturnError(&errorDict)

        if let errorDict = errorDict {
            let msg = (errorDict[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
            if msg.contains("User canceled") {
                throw AppError.tunneldAuthorizationCancelled
            }
            throw AppError.tunneldAuthorizationFailed(msg)
        }
        logger.info("tunneld launched in background as root")
    }

    static func kill() async throws {
        let script = "do shell script \"pkill -f 'pymobiledevice3 remote tunneld'\" with administrator privileges"
        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        _ = appleScript?.executeAndReturnError(&errorDict)
        if let errorDict = errorDict {
            let msg = (errorDict[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
            if msg.contains("User canceled") {
                throw AppError.tunneldAuthorizationCancelled
            }
            throw AppError.tunneldAuthorizationFailed(msg)
        }
    }

    // MARK: Helpers

    private static func findPymobiledevice3Path() -> String? {
        let common = [
            "/Users/\(NSUserName())/.local/bin/pymobiledevice3",
            "/opt/homebrew/bin/pymobiledevice3",
            "/usr/local/bin/pymobiledevice3",
        ]
        return common.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - TunnelRecoveryCoordinator

/// Drives the silent reconnect "ladder" when an RSD tunnel drops mid-session.
/// Pure policy: it owns the retry/backoff/escalation strategy and delegates all
/// I/O to `MobileDeviceClient`. It never touches UI — callers decide what to do
/// with `.recovered` / `.failed`.
///
/// Ladder (cheapest rung first, sudo only as last resort):
///  - L1: tunnel may already be back              → `verifyTunnel`
///  - L2: daemon alive but device tunnel missing  → backoff-poll `verifyTunnel`
///  - L3: daemon dead, or L2 exhausted            → `forceRestartTunneld` (sudo)
@MainActor
final class TunnelRecoveryCoordinator {

    // MARK: - Public Types

    enum Result {
        case recovered
        case failed
    }

    // MARK: - Private Properties

    private let client: MobileDeviceClient
    private let logger = AppLogger.shared

    /// Reentrancy guard: a tunnel drop can be observed by both the inline
    /// command path and the health-check timer at once. Both join the same
    /// in-flight attempt instead of racing two recoveries.
    private var inFlight: Task<Result, Never>?

    /// Overall wall-clock budget for one recovery attempt.
    private static let overallTimeout: TimeInterval = 25.0
    /// Backoff schedule (seconds) while waiting for tunneld to rebuild the tunnel.
    private static let backoffs: [UInt64] = [1, 2, 4]

    // MARK: - Init

    init(client: MobileDeviceClient) {
        self.client = client
    }

    // MARK: - Public Methods

    func recover(udid: String) async -> Result {
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { [weak self] () -> Result in
            guard let self else { return .failed }
            return await self.runLadder(udid: udid)
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    // MARK: - Private Methods

    private func runLadder(udid: String) async -> Result {
        let deadline = Date().addingTimeInterval(Self.overallTimeout)
        logger.info("Tunnel recovery started for \(udid)")

        // L1 — maybe the tunnel is already back.
        if await client.verifyTunnel(udid: udid) {
            logger.info("Tunnel recovery L1: tunnel already live")
            return .recovered
        }

        // L3 short-circuit — daemon is gone, no point backing off.
        if await client.tunneldProcessAlive() == false {
            logger.warn("Tunnel recovery: tunneld process dead, restarting (sudo)")
            return await restartAndVerify(udid: udid, deadline: deadline)
        }

        // L2 — daemon alive but this device has no tunnel; give it time to rebuild.
        for (attempt, secs) in Self.backoffs.enumerated() {
            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: secs * 1_000_000_000)
            if await client.verifyTunnel(udid: udid) {
                logger.info("Tunnel recovery L2: tunnel rebuilt after \(attempt + 1) retries")
                return .recovered
            }
        }

        // L3 — last resort, force-restart the daemon (sudo).
        logger.warn("Tunnel recovery L3: force-restarting tunneld (sudo)")
        return await restartAndVerify(udid: udid, deadline: deadline)
    }

    private func restartAndVerify(udid: String, deadline: Date) async -> Result {
        do {
            try await client.forceRestartTunneld()
        } catch {
            logger.error("Tunnel recovery restart failed: \(error.localizedDescription)")
            return .failed
        }
        while Date() < deadline {
            if await client.verifyTunnel(udid: udid) {
                logger.info("Tunnel recovery: tunnel live after restart")
                return .recovered
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        logger.error("Tunnel recovery failed for \(udid)")
        return .failed
    }
}
