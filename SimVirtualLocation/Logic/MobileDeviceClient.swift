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

        func stop() async {
            guard task.isRunning else { return }
            task.terminate()
            let start = Date()
            while task.isRunning && Date().timeIntervalSince(start) < 2.0 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if task.isRunning {
                kill(task.processIdentifier, SIGKILL)
                try? await Task.sleep(nanoseconds: 100_000_000)
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
