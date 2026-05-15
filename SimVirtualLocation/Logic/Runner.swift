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

    private let log = AppLogger.shared

    // MARK: - Utility Tools

    /// Wait for Process to end (replaces blocking task.waitUntilExit())
    private func waitExit(_ task: Process) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            task.terminationHandler = { _ in cont.resume() }
        }
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
