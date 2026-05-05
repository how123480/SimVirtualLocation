//
//  Runner.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 19.05.2022.
//
//  External command (pymobiledevice3 / adb / xcrun simctl) executor.
//  - Unified Process wrapping with async / await, no longer mixing DispatchQueue callbacks
//  - All error outputs are consolidated through AppLogger
//

import Foundation
import CoreLocation

class Runner {

    // MARK: - Public Properties

    /// Minimum interval (seconds) between location updates during route simulation
    var timeDelay: TimeInterval = 0.5

    // MARK: - Private Properties

    /// Currently running location Process (used to terminate old commands before switching to new ones)
    private var currentTask: Process?

    private let log = AppLogger.shared

    // MARK: - Utility Tools

    /// Filter known harmless warnings (urllib3 / LibreSSL)
    private func shouldSuppressError(_ error: String) -> Bool {
        if error.contains("NotOpenSSLWarning") ||
           error.contains("urllib3 v2 only supports OpenSSL") ||
           error.contains("LibreSSL") {
            return true
        }
        if error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    /// Wait for Process to end (replaces blocking task.waitUntilExit())
    private func waitExit(_ task: Process) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            task.terminationHandler = { _ in cont.resume() }
        }
    }

    // MARK: - Developer Mode

    enum DeveloperModeStatus {
        case enabled
        case needsManual
        case failed(String)
    }

    func checkDeveloperModeStatus(udid: String) async -> Bool {
        do {
            let task = try await taskForIOS(args: ["amfi", "developer-mode-status", "--udid", udid])
            let outputPipe = Pipe()
            task.standardOutput = outputPipe

            try task.run()
            await waitExit(task)

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            log.info("Developer Mode status: \(output)")
            return output.contains("true")
        } catch {
            log.error("Failed to check Developer Mode: \(error.localizedDescription)")
            return false
        }
    }

    func revealDeveloperMode(udid: String) async {
        do {
            let task = try await taskForIOS(args: ["amfi", "reveal-developer-mode", "--udid", udid])
            log.info("Prompting device to open Developer Mode menu")
            try task.run()
            await waitExit(task)
        } catch {
            log.error("reveal-developer-mode failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Terminate Current Command

    func stopCurrentTask() async {
        guard let task = currentTask, task.isRunning else { return }

        log.debug("Terminating previous location command")
        task.terminate()

        // Wait for process to end (max 2 seconds)
        let start = Date()
        while task.isRunning && Date().timeIntervalSince(start) < 2.0 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if task.isRunning {
            log.warn("Old command did not end within time limit, forcing clear")
        } else {
            log.debug("Old command has ended")
        }
        currentTask = nil
    }

    // MARK: - Simulator Location

    func runOnSimulator(
        location: CLLocationCoordinate2D,
        selectedSimulator: String,
        bootedSimulators: [Simulator]
    ) {
        let simulators = bootedSimulators
            .filter { $0.id == selectedSimulator || selectedSimulator == "" }
            .map { $0.id }

        log.info("Simulator location: lat=\(location.latitude), lng=\(location.longitude)")
        NotificationSender.postNotification(for: location, to: simulators)
    }

    // MARK: - iOS 16 and Below Location

    func runOnIos(
        location: CLLocationCoordinate2D,
        udid: String,
        showAlert: @escaping (String) -> Void
    ) async throws {
        let task = try await taskForIOS(args: [
            "developer", "simulate-location", "set",
            "--udid", udid,
            "--",
            String(format: "%.5f", location.latitude),
            String(format: "%.5f", location.longitude),
        ])
        try await runLocationTask(task, label: "iOS legacy", showAlert: showAlert)
    }

    // MARK: - iOS 17+ RSD Location

    func runOnNewIos(
        location: CLLocationCoordinate2D,
        udid: String,
        RSDAddress: String,
        RSDPort: String,
        showAlert: @escaping (String) -> Void
    ) async throws {
        guard !RSDAddress.isEmpty, !RSDPort.isEmpty else {
            showAlert("RSD Address / Port not yet obtained")
            return
        }

        let task = try await taskForIOS(args: [
            "developer", "dvt", "simulate-location", "set",
            "--rsd", RSDAddress, RSDPort,
            "--",
            "\(location.latitude)",
            "\(location.longitude)",
        ])
        try await runLocationTask(task, label: "iOS RSD", showAlert: showAlert)
    }

    /// Shared location command execution flow
    private func runLocationTask(
        _ task: Process,
        label: String,
        showAlert: @escaping (String) -> Void
    ) async throws {
        log.debug("Executing \(label) location command: \(task.logDescription)")

        currentTask = task

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardInput = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()
            await waitExit(task)
            currentTask = nil

            // Termination signal (15 = SIGTERM) is expected, do not report as error
            if task.terminationStatus != 0 && task.terminationStatus != 15 {
                if let data = try errPipe.fileHandleForReading.readToEnd() {
                    let err = String(decoding: data, as: UTF8.self)
                    if !err.isEmpty && !shouldSuppressError(err) {
                        showAlert(err)
                        log.error("\(label) failed: \(err)")
                    } else if !err.isEmpty {
                        log.debug("Suppressing harmless warning: \(err.prefix(120))")
                    }
                }
            } else if task.terminationStatus == 15 {
                log.debug("Location command terminated (SIGTERM), skipping error output")
            }
        } catch {
            currentTask = nil
            showAlert(error.localizedDescription)
            log.error("\(label) start failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - iOS GPX Playback (long-running)

    /// Plays GPX file via pymobiledevice3, suitable for iOS 16 and below.
    /// This process will continue running until the GPX ends or it is terminated by SIGTERM.
    func playGPXLegacy(
        udid: String,
        gpxURL: URL,
        showAlert: @escaping (String) -> Void
    ) async throws {
        let task = try await taskForIOS(args: [
            "developer", "simulate-location", "play",
            "--udid", udid,
            gpxURL.path,
        ])
        try await runLocationTask(task, label: "iOS legacy GPX play", showAlert: showAlert)
    }

    /// Plays GPX file via pymobiledevice3, suitable for iOS 17+ RSD mode.
    func playGPXRSD(
        udid: String,
        gpxURL: URL,
        RSDAddress: String,
        RSDPort: String,
        showAlert: @escaping (String) -> Void
    ) async throws {
        guard !RSDAddress.isEmpty, !RSDPort.isEmpty else {
            showAlert("RSD Address / Port not yet obtained")
            return
        }
        let task = try await taskForIOS(args: [
            "developer", "dvt", "simulate-location", "play",
            "--rsd", RSDAddress, RSDPort,
            gpxURL.path,
        ])
        try await runLocationTask(task, label: "iOS RSD GPX play", showAlert: showAlert)
    }

    // MARK: - Android Location

    func runOnAndroid(
        location: CLLocationCoordinate2D,
        adbDeviceId: String,
        adbPath: String,
        isEmulator: Bool,
        showAlert: @escaping (String) -> Void
    ) async {
        let task: Process
        if isEmulator {
            task = taskForAndroid(args: [
                "-s", adbDeviceId,
                "emu", "geo", "fix",
                "\(location.longitude)",
                "\(location.latitude)",
            ], adbPath: adbPath)
        } else {
            task = taskForAndroid(args: [
                "-s", adbDeviceId,
                "shell", "am", "broadcast",
                "-a", "send.mock",
                "-e", "lat", "\(location.latitude)",
                "-e", "lon", "\(location.longitude)",
            ], adbPath: adbPath)
        }

        log.info("Android location: lat=\(location.latitude), lng=\(location.longitude)")
        log.debug("Android command: \(task.logDescription)")

        let errPipe = Pipe()
        task.standardError = errPipe

        do {
            try task.run()
            await waitExit(task)
        } catch {
            showAlert(error.localizedDescription)
            log.error("Android command failed: \(error.localizedDescription)")
            return
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let err = String(decoding: errData, as: UTF8.self)
        if !err.isEmpty {
            showAlert(err)
            log.error("Android stderr: \(err)")
        }
    }

    // MARK: - Reset / Stop Location

    func resetIos(
        udid: String,
        useRSD: Bool,
        RSDAddress: String,
        RSDPort: String,
        showAlert: @escaping (String) -> Void
    ) async {
        await stopCurrentTask()

        do {
            let args: [String]
            if useRSD && !RSDAddress.isEmpty && !RSDPort.isEmpty {
                args = ["developer", "dvt", "simulate-location", "clear", "--rsd", RSDAddress, RSDPort]
            } else {
                args = ["developer", "simulate-location", "clear", "--udid", udid]
            }

            let task = try await taskForIOS(args: args)
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe

            try task.run()
            await waitExit(task)

            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            if task.terminationStatus == 0 {
                log.info("iOS mock location cleared")
            } else {
                let msg = String(decoding: output, as: UTF8.self)
                log.warn("Failed to clear iOS mock location: \(msg)")
            }
        } catch {
            log.error("Error clearing iOS mock location: \(error.localizedDescription)")
        }
    }

    func resetAndroid(adbDeviceId: String, adbPath: String, showAlert: (String) -> Void) {
        let task = taskForAndroid(args: [
            "-s", adbDeviceId,
            "shell", "am", "broadcast",
            "-a", "stop.mock",
        ], adbPath: adbPath)

        let errPipe = Pipe()
        task.standardError = errPipe

        do {
            try task.run()
        } catch {
            showAlert(error.localizedDescription)
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let err = String(decoding: errData, as: UTF8.self)
        if !err.isEmpty {
            showAlert(err)
        }
        task.waitUntilExit()
    }

    // MARK: - Path Search

    func getFullPathOf(_ command: String) -> String? {
        // Prioritize common installation locations
        let common = [
            "/Users/\(NSUserName())/.local/bin/\(command)",
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/usr/bin/\(command)",
        ]
        for p in common where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }

        // Backup: use which with expanded PATH environment variable
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [command]

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
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty ?? true) ? nil : path
        } catch {
            return nil
        }
    }

    // MARK: - Create Process

    /// Create pymobiledevice3 Process for iOS. Throws error if tool does not exist.
    func taskForIOS(args: [String]) async throws -> Process {
        guard let pymobile = getFullPathOf("pymobiledevice3") else {
            throw NSError(domain: "Runner", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not find pymobiledevice3, please install it and retry (pip install pymobiledevice3)"
            ])
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: pymobile)
        task.arguments = args
        return task
    }

    private func taskForAndroid(args: [String], adbPath: String) -> Process {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = args
        return task
    }
}

extension CLLocationCoordinate2D {
    var description: String { "\(latitude) \(longitude)" }
}

extension Process {
    var logDescription: String {
        var s = ""
        if let url = executableURL {
            // Anonymization (home directory, UDID, etc.)
            s += "\(Sanitizer.sanitize(url.path)) "
        }
        if let args = arguments {
            s += Sanitizer.sanitize(args.joined(separator: " "))
        }
        return s
    }
}
