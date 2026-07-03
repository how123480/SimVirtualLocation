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

    /// Currently running long-lived process (GPX play). At most one.
    private var currentLongRunning: ProcessRunner.LongRunningHandle?

    // MARK: - Init

    init() {}

    // MARK: - Device discovery

    func listDevices() async throws -> [Device] {
        let result = try await processRunner.run(args: ["--no-color", "usbmux", "list"])
        if result.exitCode != 0 {
            throw AppError.from(stderr: result.stderr, context: .listDevices)
        }
        let devices = try JSONDecoder().decode([Device].self, from: result.stdout)
        var seen: Set<String> = []
        let unique = devices.filter { seen.insert($0.id).inserted && $0.isUSB }
        logger.info("Connected USB devices: \(unique.map { "\($0.name) (\($0.version))" }.joined(separator: ", "))")
        return unique
    }

    // MARK: - Developer Mode

    func checkDeveloperMode(udid: String) async throws -> Bool {
        let result = try await processRunner.run(args: ["amfi", "developer-mode-status", "--udid", udid])
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
        _ = try await processRunner.run(args: ["amfi", "reveal-developer-mode", "--udid", udid])
        // reveal-developer-mode is best-effort; ignore exit code.
    }

    // MARK: - Mount Developer Image

    func mountDeveloperImage(udid: String) async throws -> MountResult {
        let result = try await processRunner.run(args: ["mounter", "auto-mount", "--udid", udid])

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
        let result = try await processRunner.run(args: args)
        try classifyResult(result, context: .setLocation)
    }

    func clearLocation(transport: Transport) async throws {
        if case .rsd = transport {
            try await ensureTunneldRunning()
        }
        let args = locationClearArgs(transport)
        let result = try await processRunner.run(args: args)
        try classifyResult(result, context: .clearLocation)
    }

    /// Plays GPX in the background. Returns a handle the caller stores.
    /// Calling stop() on the handle SIGTERMs the underlying process.
    func playGPX(_ url: URL, transport: Transport) async throws -> ProcessRunner.LongRunningHandle {
        if case .rsd = transport {
            try await ensureTunneldRunning()
        }
        // Stop any previously running long-running task first.
        await currentLongRunning?.stop()
        currentLongRunning = nil

        let args = locationPlayArgs(url, transport: transport)
        let handle = try processRunner.runDiscardingOutput(args: args)
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

    func ensureTunneldRunning() async throws {
        if case .ready = tunneldStatus { return }

        if await TunneldSupervisor.isRunning() {
            logger.info("tunneld already running, polling for HTTP readiness")
            tunneldStatus = .launching
            try await TunneldSupervisor.waitForReady(url: tunneldHostURL, timeout: 30.0)
            tunneldStatus = .ready
            logger.info("tunneld is ready")
            return
        }

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
        init(_ task: Process) { self.task = task }

        var isRunning: Bool { task.isRunning }

        // pymobiledevice3 is a Python wrapper that may spawn subprocesses
        // (asyncio workers, tunnel I/O helpers). Signalling only the parent
        // can leave the play loop running, so we walk the descendant tree.
        func stop() async {
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

    func run(args: [String]) async throws -> ProcessResult {
        let task = try makeTask(args: args)
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardInput = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        try task.run()
        await waitExit(task)
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(exitCode: task.terminationStatus, stdout: out, stderr: err)
    }

    // MARK: Long-running (output discarded to avoid pipe buffer deadlock)

    func runDiscardingOutput(args: [String]) throws -> LongRunningHandle {
        let task = try makeTask(args: args)
        let devNull = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = devNull
        task.standardError = devNull
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

    private func waitExit(_ task: Process) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            task.terminationHandler = { _ in cont.resume() }
        }
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

    private static func isReachable(url: URL) async -> Bool {
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
