//
//  Runner.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 19.05.2022.
//

import Foundation
import CoreLocation

class Runner {

    // MARK: - Internal Properties

    var timeDelay: TimeInterval = 0.5
    var log: ((String) -> Void)?

    // MARK: - Private Properties

    private let runnerQueue = DispatchQueue(label: "runnerQueue", qos: .background)
    private let executionQueue = DispatchQueue(label: "executionQueue", qos: .background, attributes: .concurrent)
    private var idevicelocationPath: URL?

    private var currentTask: Process?
    private var tasks: [Process] = []
    private let maxTasksCount = 10

    private var isStopped: Bool = false

    // MARK: - Internal Methods
    
    /// Filters out known benign warnings from error messages
    private func shouldSuppressError(_ error: String) -> Bool {
        // Suppress urllib3 OpenSSL/LibreSSL warnings (common on macOS)
        if error.contains("NotOpenSSLWarning") || 
           error.contains("urllib3 v2 only supports OpenSSL") ||
           error.contains("LibreSSL") {
            return true
        }
        
        // Suppress empty or whitespace-only errors
        if error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        
        return false
    }

    func stop() {
        tasks.forEach { $0.terminate() }
        tasks = []

        isStopped = true
    }
    
    func stopCurrentTask() async {
        guard let task = currentTask, task.isRunning else {
            return
        }
        
        log?("Stopping current location task to start new one")
        task.terminate()
        
        // Wait asynchronously for the task to exit (up to 2 seconds)
        let startTime = Date()
        let timeout: TimeInterval = 2.0
        
        while task.isRunning && Date().timeIntervalSince(startTime) < timeout {
            try? await Task.sleep(nanoseconds: 50_000_000) // Sleep 50ms
        }
        
        if task.isRunning {
            log?("Warning: Task did not exit within timeout, forcing cleanup")
        } else {
            log?("Previous task stopped successfully")
        }
        
        currentTask = nil
    }
    
    func runOnSimulator(
        location: CLLocationCoordinate2D,
        selectedSimulator: String,
        bootedSimulators: [Simulator],
        showAlert: @escaping (String) -> Void
    ) {
        let simulators = bootedSimulators
            .filter { $0.id == selectedSimulator || selectedSimulator == "" }
            .map { $0.id }

        log?("set simulator location \(location.description)")

        NotificationSender.postNotification(for: location, to: simulators)
    }
    
    func runOnIos(
        location: CLLocationCoordinate2D,
        showAlert: @escaping (String) -> Void
    ) async throws {
        self.isStopped = false

        guard !self.isStopped else {
            return
        }

        let task = try await self.taskForIOS(
            args: [
                "developer",
                "simulate-location",
                "set",
                "--",
                "\(String(format: "%.5f", location.latitude))",
                "\(String(format: "%.5f", location.longitude))"
            ],
            showAlert: showAlert
        )

        self.log?("set iOS location \(location.description)")
        self.log?("task: \(task.logDescription)")

        self.currentTask = task

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        task.standardInput = inputPipe
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        do {
            try task.run()
            self.runnerQueue.async {
                if self.tasks.count > self.maxTasksCount {
                    self.stop()
                }
                self.tasks.append(task)
            }

            task.waitUntilExit()
            
            // Clear currentTask reference after task exits
            self.currentTask = nil

            // Only show errors if task wasn't terminated (exit code 15 = SIGTERM)
            // When terminated by stopCurrentTask(), SSL errors are expected and should be ignored
            if task.terminationStatus != 15 {
                if let errorData = try errorPipe.fileHandleForReading.readToEnd() {
                    let error = String(decoding: errorData, as: UTF8.self)

                    // Filter out known benign warnings (urllib3, LibreSSL, etc.)
                    if !error.isEmpty && !self.shouldSuppressError(error) {
                        showAlert(error)
                    } else if !error.isEmpty {
                        self.log?("Suppressed benign warning: \(error.prefix(100))...")
                    }
                }
            } else {
                self.log?("Task terminated (exit code 15), errors suppressed")
            }
        } catch {
            self.currentTask = nil
            showAlert(error.localizedDescription)
            return
        }
    }

    func runOnNewIos(
        location: CLLocationCoordinate2D,
        RSDAddress: String,
        RSDPort: String,
        showAlert: @escaping (String) -> Void
    ) async throws {
        guard !RSDAddress.isEmpty, !RSDPort.isEmpty else {
            showAlert("Please specify RSD ID and Port")
            return
        }

        self.isStopped = false

        guard !self.isStopped else {
            return
        }

        let task = try await self.taskForIOS(
            args: [
                "developer",
                "dvt",
                "simulate-location",
                "set",
                "--rsd",
                RSDAddress,
                RSDPort,
                "--",
                "\(location.latitude)",
                "\(location.longitude)"
            ],
            showAlert: showAlert
        )

        self.log?("set iOS location \(location.description)")
        self.log?("task: \(task.logDescription)")

        self.currentTask = task

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        task.standardInput = inputPipe
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        do {
            try task.run()
            self.runnerQueue.async {
                if self.tasks.count > self.maxTasksCount {
                    self.stop()
                }
                self.tasks.append(task)
            }

            task.waitUntilExit()
            
            // Clear currentTask reference after task exits
            self.currentTask = nil

            // Only show errors if task wasn't terminated (exit code 15 = SIGTERM)
            // When terminated by stopCurrentTask(), SSL errors are expected and should be ignored
            if task.terminationStatus != 15 {
                if let errorData = try errorPipe.fileHandleForReading.readToEnd() {
                    let error = String(decoding: errorData, as: UTF8.self)

                    // Filter out known benign warnings (urllib3, LibreSSL, etc.)
                    if !error.isEmpty && !self.shouldSuppressError(error) {
                        showAlert(error)
                    } else if !error.isEmpty {
                        self.log?("Suppressed benign warning: \(error.prefix(100))...")
                    }
                }
            } else {
                self.log?("Task terminated (exit code 15), errors suppressed")
            }
        } catch {
            self.currentTask = nil
            showAlert(error.localizedDescription)
            return
        }
    }
    
    func runOnAndroid(
        location: CLLocationCoordinate2D,
        adbDeviceId: String,
        adbPath: String,
        isEmulator: Bool,
        showAlert: @escaping (String) -> Void
    ) {
        executionQueue.async {
            let task: Process
            
            if isEmulator {
                task = self.taskForAndroid(
                    args: [
                        "-s", adbDeviceId,
                        "emu", "geo", "fix",
                        "\(location.longitude)",
                        "\(location.latitude)"
                    ],
                    adbPath: adbPath
                )
            } else {
                task = self.taskForAndroid(
                    args: [
                        "-s", adbDeviceId,
                        "shell", "am", "broadcast",
                        "-a", "send.mock",
                        "-e", "lat", "\(location.latitude)",
                        "-e", "lon", "\(location.longitude)"
                    ],
                    adbPath: adbPath
                )
            }
            
            self.log?("set Android location \(location.description)")
            self.log?("task: \(task.logDescription)")

            let errorPipe = Pipe()
            
            task.standardError = errorPipe
            
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                showAlert(error.localizedDescription)
                return
            }
            
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let error = String(decoding: errorData, as: UTF8.self)
            
            if !error.isEmpty {
                showAlert(error)
            }
        }
    }
    
    func resetIos(
        useRSD: Bool,
        RSDAddress: String,
        RSDPort: String,
        showAlert: @escaping (String) -> Void
    ) {
        stop()
        
        // Clear location simulation on iOS device
        Task {
            do {
                var args = ["developer", "dvt", "simulate-location", "clear"]
                
                // Add RSD tunnel parameters if enabled
                if useRSD && !RSDAddress.isEmpty && !RSDPort.isEmpty {
                    args.append(contentsOf: ["--rsd", RSDAddress, RSDPort])
                }
                
                let task = try await taskForIOS(args: args, showAlert: showAlert)
                
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe
                
                try task.run()
                task.waitUntilExit()
                
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                pipe.fileHandleForReading.closeFile()
                
                if task.terminationStatus == 0 {
                    log?("Successfully cleared iOS location simulation")
                } else {
                    let errorMessage = String(decoding: output, as: UTF8.self)
                    log?("Failed to clear iOS location simulation: \(errorMessage)")
                }
            } catch {
                log?("Error clearing iOS location simulation: \(error.localizedDescription)")
            }
        }
    }
    
    func resetAndroid(adbDeviceId: String, adbPath: String, showAlert: (String) -> Void) {
        let task = taskForAndroid(
            args: [
                "-s", adbDeviceId,
                "shell", "am", "broadcast",
                "-a", "stop.mock"
            ],
            adbPath: adbPath
        )
        
        let errorPipe = Pipe()
        
        task.standardError = errorPipe
        
        do {
            try task.run()
        } catch {
            showAlert(error.localizedDescription)
        }
        
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let error = String(decoding: errorData, as: UTF8.self)
        
        if !error.isEmpty {
            showAlert(error)
        }
        
        task.waitUntilExit()
    }

    func getFullPathOf(_ command: String) -> String? {
        // Common installation paths for command-line tools
        let commonPaths = [
            "/Users/\(NSUserName())/.local/bin/\(command)",
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/usr/bin/\(command)",
        ]
        
        // Check common paths first
        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) && FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        
        // Fallback: try using 'which' command with expanded PATH
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [command]
        
        // Set a comprehensive PATH that includes common locations
        var environment = ProcessInfo.processInfo.environment
        let expandedPath = [
            "/Users/\(NSUserName())/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")
        environment["PATH"] = expandedPath
        task.environment = environment
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty ?? true) ? nil : path
        } catch {
            return nil
        }
    }

    func taskForIOS(args: [String], showAlert: (String) -> Void) async throws -> Process {
        let pymobiledeivcePath = getFullPathOf("pymobiledevice3")
        if pymobiledeivcePath == nil {
            showAlert("pymobiledevice3 not found. Please install it using 'pip install pymobiledevice3' and ensure it's in your PATH.")
            throw NSError(domain: "Runner", code: 1, userInfo: [NSLocalizedDescriptionKey: "pymobiledevice3 not found"])
        }
        let path: URL = URL(fileURLWithPath: pymobiledeivcePath!)
        let task = Process()
        task.executableURL = path
        task.arguments = args

        return task
    }

    // MARK: - Private Methods

    private func taskForAndroid(args: [String], adbPath: String) -> Process {
        let path = adbPath
        let task = Process()
        task.executableURL = URL(string: "file://\(path)")!
        task.arguments = args
        
        return task
    }
}

extension CLLocationCoordinate2D {

    var description: String { "\(latitude) \(longitude)" }
}

extension Process {

    var logDescription: String {
        var description: String = ""
        if let executableURL {
            description += "\(executableURL.absoluteString) "
        }

        if let arguments {
            description += "\(arguments.joined(separator: " "))"
        }

        return description
    }
}
