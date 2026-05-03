//
//  Logger.swift
//  SimVirtualLocation
//
//  Unified Logging System:
//  - Provides graded logs (debug / info / warn / error)
//  - Simultaneously outputs to memory (UI display), stdout, and file
//  - Automatically performs file rotation (single file limit + backup count)
//  - Built-in anonymization (home directory, UDID, IPv6, coordinates)
//
//  Log file location: ~/Library/Logs/SimVirtualLocation/app.log
//

import Foundation

// MARK: - Log Levels

enum LogLevel: Int, Comparable {
    case debug = 0
    case info  = 1
    case warn  = 2
    case error = 3

    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info:  return "INFO "
        case .warn:  return "WARN "
        case .error: return "ERROR"
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - AppLogger

final class AppLogger {

    // MARK: Singleton
    static let shared = AppLogger()

    // MARK: Configuration
    /// Single log file size limit (bytes), rotate when exceeded
    private let maxFileSize: Int = 1 * 1024 * 1024 // 1 MB
    /// Number of historical log files to keep (excluding current file)
    private let maxBackupCount: Int = 5
    /// Minimum output level for stdout and file (UI will still receive all debug and above)
    private let minLevel: LogLevel = .debug

    // MARK: Internal State
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.simvloc.logger", qos: .utility)
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Observers (for UI display), uses weak reference to avoid cycles
    private var observers: [(LogEntry) -> Void] = []

    // MARK: Init

    private init() {
        let fm = FileManager.default
        let baseDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("SimVirtualLocation", isDirectory: true)
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        self.fileURL = baseDir.appendingPathComponent("app.log")
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    // MARK: Observer Registration

    /// Register UI observer (callback will be on main thread)
    func addObserver(_ callback: @escaping (LogEntry) -> Void) {
        queue.async { [weak self] in
            self?.observers.append(callback)
        }
    }

    // MARK: Public Logging API

    func debug(_ message: @autoclosure () -> String, file: String = #fileID, function: String = #function, line: Int = #line) {
        log(.debug, message(), file: file, function: function, line: line)
    }

    func info(_ message: @autoclosure () -> String, file: String = #fileID, function: String = #function, line: Int = #line) {
        log(.info, message(), file: file, function: function, line: line)
    }

    func warn(_ message: @autoclosure () -> String, file: String = #fileID, function: String = #function, line: Int = #line) {
        log(.warn, message(), file: file, function: function, line: line)
    }

    func error(_ message: @autoclosure () -> String, file: String = #fileID, function: String = #function, line: Int = #line) {
        log(.error, message(), file: file, function: function, line: line)
    }

    /// Get current log file path (anonymized)
    var displayLogPath: String { Sanitizer.sanitize(fileURL.path) }

    // MARK: Internal Log Implementation

    private func log(_ level: LogLevel, _ rawMessage: String, file: String, function: String, line: Int) {
        let timestamp = Date()
        // Unified anonymization
        let safeMessage = Sanitizer.sanitize(rawMessage)
        let location = "\(Sanitizer.shortFile(file)):\(line)"
        // Unified format: [timestamp] [level] [file:line] message
        let formatted = "[\(isoFormatter.string(from: timestamp))] [\(level.label)] [\(location)] \(safeMessage)"

        let entry = LogEntry(date: timestamp, level: level, message: safeMessage, location: location)

        queue.async { [weak self] in
            guard let self else { return }
            // 1. stdout (debug and above)
            if level >= self.minLevel {
                print(formatted)
            }
            // 2. Write to file
            self.writeToFile(formatted)
            // 3. Notify UI observers
            let observers = self.observers
            DispatchQueue.main.async {
                observers.forEach { $0(entry) }
            }
        }
    }

    // MARK: File Rotation

    private func writeToFile(_ line: String) {
        let data = (line + "\n").data(using: .utf8) ?? Data()
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // No retry on write failure to avoid infinite recursion
            print("[Logger] Write failed: \(error.localizedDescription)")
            return
        }
        rotateIfNeeded()
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int,
              size >= maxFileSize else {
            return
        }
        // Move from oldest to newest: app.log.5 deleted, app.log.4 -> app.log.5 ...
        for i in stride(from: maxBackupCount, through: 1, by: -1) {
            let src = fileURL.deletingLastPathComponent()
                .appendingPathComponent("app.log.\(i)")
            let dst = fileURL.deletingLastPathComponent()
                .appendingPathComponent("app.log.\(i + 1)")
            if fm.fileExists(atPath: dst.path) {
                try? fm.removeItem(at: dst)
            }
            if fm.fileExists(atPath: src.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }
        // app.log -> app.log.1
        let firstBackup = fileURL.deletingLastPathComponent().appendingPathComponent("app.log.1")
        if fm.fileExists(atPath: firstBackup.path) {
            try? fm.removeItem(at: firstBackup)
        }
        try? fm.moveItem(at: fileURL, to: firstBackup)
        fm.createFile(atPath: fileURL.path, contents: nil)
    }
}

// MARK: - Sanitization Tools

enum Sanitizer {
    /// Replace sensitive information (home directory, UDID, IPv6, coordinate precision)
    static func sanitize(_ text: String) -> String {
        var result = text
        // 1. Home directory path -> ~
        let home = NSHomeDirectory()
        if !home.isEmpty {
            result = result.replacingOccurrences(of: home, with: "~")
        }
        // 2. /Users/<user>/ -> /Users/<user>/
        result = result.replacingOccurrences(
            of: #"/Users/[^/\s]+"#,
            with: "/Users/<user>",
            options: .regularExpression
        )
        // 3. UDID (25/40 hex or standard UUID) keep only first 4 and last 4
        result = result.replacingOccurrences(
            of: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{16}\b"#,
            with: "<udid>",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\b[0-9a-fA-F]{40}\b"#,
            with: "<udid>",
            options: .regularExpression
        )
        // 4. IPv6 link-local (including zone)
        result = result.replacingOccurrences(
            of: #"fe80:[0-9a-fA-F:]+(%\w+)?"#,
            with: "<ipv6>",
            options: .regularExpression
        )
        return result
    }

    /// Extract filename (without path)
    static func shortFile(_ fileID: String) -> String {
        // #fileID is usually "ModuleName/File.swift"
        return fileID.components(separatedBy: "/").last ?? fileID
    }
}
