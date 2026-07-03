//
//  LocationHelperClient.swift
//  SimVirtualLocation
//
//  Owns the persistent Python location helper: one process per connected RSD
//  device, line-JSON protocol, strict FIFO request→response pairing. A command
//  timeout is treated as protocol desync and kills the helper; unexpected
//  death auto-restarts (capped) and re-sends the last coordinate so
//  single-point mocking never silently reverts.
//

import Foundation
import CoreLocation

@MainActor
final class LocationHelperClient {

    // MARK: - Enums

    enum HelperError: Error {
        /// The installed pymobiledevice3 cannot run the helper (no usable
        /// shebang, or import layout differs). Sticky — callers fall back to
        /// the one-shot CLI for the rest of the app run.
        case unsupported(String)
        case notRunning
        case startFailed(String)
        case commandFailed(String)
        case timeout
    }

    // MARK: - Public Properties

    var isRunning: Bool { process?.isRunning == true }

    /// UDID the current helper process serves; nil when never started.
    var servedUDID: String? { udid }

    // MARK: - Private Properties

    private let logger = AppLogger.shared
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var pending: [(id: Int, continuation: CheckedContinuation<[String: Any], Error>)] = []
    private var nextCommandID = 0
    private var lastSetCoordinate: CLLocationCoordinate2D?
    private var restartCount = 0
    /// True once the current spawn's ready line was received. A process that
    /// dies before ready is a start failure (already reported to the caller),
    /// never an auto-restart candidate.
    private var didBecomeReady = false
    /// Incremented per spawn; the termination handler captures its value so a
    /// stale process's late death notification can't tear down a newer spawn.
    private var spawnGeneration = 0
    private var udid: String?
    private var pymobiledevice3Path: String?
    private var intentionalShutdown = false

    private static let startTimeout: TimeInterval = 15
    private static let commandTimeout: TimeInterval = 5
    private static let maxAutoRestarts = 3

    // MARK: - Public Methods

    /// Starts (or restarts) the helper for `udid`. Resets the auto-restart cap.
    func start(udid: String, pymobiledevice3Path: String) async throws {
        self.udid = udid
        self.pymobiledevice3Path = pymobiledevice3Path
        restartCount = 0
        try await spawn()
    }

    func set(_ coord: CLLocationCoordinate2D) async throws {
        _ = try await sendCommand(["cmd": "set", "lat": coord.latitude, "lng": coord.longitude])
        lastSetCoordinate = coord
        logger.debug("Helper set: lat=\(coord.latitude), lng=\(coord.longitude)")
    }

    func clear() async throws {
        lastSetCoordinate = nil
        _ = try await sendCommand(["cmd": "clear"])
        logger.info("Helper cleared simulated location")
    }

    /// Drops the remembered coordinate WITHOUT touching the device. Called
    /// when GPX playback takes over the location so a helper auto-restart
    /// can't re-assert a stale single-point fix mid-route.
    func forgetLastSetCoordinate() {
        lastSetCoordinate = nil
        logger.debug("Helper forgot last set coordinate (GPX playback owns location)")
    }

    /// Graceful shutdown: closing stdin makes the helper exit cleanly, which
    /// clears the simulated location on the device.
    func shutdown() async {
        spawnGeneration += 1
        intentionalShutdown = true
        readerTask?.cancel()
        readerTask = nil
        failAllPending(with: HelperError.notRunning)
        if let stdinHandle { try? stdinHandle.close() }
        stdinHandle = nil
        if let process, process.isRunning {
            logger.info("Shutting down location helper")
            let start = Date()
            while process.isRunning && Date().timeIntervalSince(start) < 2.0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning { process.terminate() }
        }
        process = nil
        lastSetCoordinate = nil
    }

    // MARK: - Private Methods

    private func spawn() async throws {
        await shutdown()
        intentionalShutdown = false
        didBecomeReady = false

        guard let udid, let pymobiledevice3Path else {
            throw HelperError.startFailed("start(udid:pymobiledevice3Path:) not called")
        }
        guard let interpreter = LocationHelperScript.findInterpreter(
            pymobiledevice3Path: pymobiledevice3Path
        ) else {
            throw HelperError.unsupported("no usable python shebang in pymobiledevice3")
        }
        let scriptURL = try LocationHelperScript.materialize()

        spawnGeneration += 1
        let generation = spawnGeneration

        let task = Process()
        task.executableURL = URL(fileURLWithPath: interpreter)
        task.arguments = [scriptURL.path, udid]
        let inPipe = Pipe()
        let outPipe = Pipe()
        task.standardInput = inPipe
        task.standardOutput = outPipe
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleTermination(exitCode: code, generation: generation)
            }
        }
        logger.info("Starting location helper for \(udid) (interpreter: \(interpreter))")
        try task.run()
        process = task
        stdinHandle = inPipe.fileHandleForWriting
        startReader(outPipe.fileHandleForReading)

        let ready = try await awaitResponse(timeout: Self.startTimeout)
        guard (ready["ready"] as? Bool) == true else {
            let message = (ready["error"] as? String) ?? "unexpected first message"
            await shutdown()
            if message.contains("unsupported") {
                throw HelperError.unsupported(message)
            }
            throw HelperError.startFailed(message)
        }
        didBecomeReady = true
        logger.info("Location helper ready")
    }

    private func startReader(_ handle: FileHandle) {
        readerTask = Task { [weak self] in
            do {
                for try await line in handle.bytes.lines {
                    self?.dispatch(line: line)
                }
            } catch {
                // Reader errors surface as EOF; termination handling cleans up.
            }
        }
    }

    private func dispatch(line: String) {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            logger.debug("Location helper non-JSON output ignored")
            return
        }
        guard !pending.isEmpty else {
            logger.debug("Location helper unsolicited message ignored")
            return
        }
        let entry = pending.removeFirst()
        entry.continuation.resume(returning: obj)
    }

    /// Writes one command and awaits exactly one response. Write + enqueue
    /// happen with no suspension in between, so concurrent callers stay FIFO.
    private func sendCommand(_ payload: [String: Any]) async throws -> [String: Any] {
        guard let stdinHandle, isRunning else { throw HelperError.notRunning }
        let data = try JSONSerialization.data(withJSONObject: payload)
        do {
            try stdinHandle.write(contentsOf: data)
            try stdinHandle.write(contentsOf: Data("\n".utf8))
        } catch {
            throw HelperError.notRunning
        }
        let response = try await awaitResponse(timeout: Self.commandTimeout)
        if (response["ok"] as? Bool) == true { return response }
        throw HelperError.commandFailed((response["error"] as? String) ?? "unknown error")
    }

    private func awaitResponse(timeout: TimeInterval) async throws -> [String: Any] {
        let id = nextCommandID
        nextCommandID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending.append((id: id, continuation: continuation))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self,
                      self.pending.contains(where: { $0.id == id }) else { return }
                // A missed deadline means the FIFO pairing is no longer
                // trustworthy for ANY in-flight command — fail them all and
                // kill the helper; termination handling restarts it.
                self.logger.warn("Location helper command timed out; restarting helper")
                self.failAllPending(with: HelperError.timeout)
                self.process?.terminate()
            }
        }
    }

    private func failAllPending(with error: Error) {
        let all = pending
        pending = []
        for entry in all { entry.continuation.resume(throwing: error) }
    }

    private func handleTermination(exitCode: Int32, generation: Int) {
        guard generation == spawnGeneration else {
            logger.debug("Ignoring stale helper termination (gen \(generation))")
            return
        }
        guard !intentionalShutdown else { return }
        guard didBecomeReady else {
            // Died before ready — a start failure the caller already saw.
            return
        }
        logger.warn("Location helper exited unexpectedly (code \(exitCode))")
        failAllPending(with: HelperError.notRunning)
        readerTask?.cancel()
        readerTask = nil
        process = nil
        stdinHandle = nil

        guard restartCount < Self.maxAutoRestarts else {
            logger.error("Location helper restart cap reached; falling back to CLI until next start")
            return
        }
        restartCount += 1
        let restartFromGeneration = spawnGeneration
        let coordinate = lastSetCoordinate
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard restartFromGeneration == self.spawnGeneration,
                  !self.intentionalShutdown else { return }
            do {
                try await self.spawn()
                if let coordinate {
                    try await self.set(coordinate)
                    self.logger.info("Location helper restarted; re-sent last coordinate")
                }
            } catch {
                self.logger.warn("Location helper restart failed: \(error.localizedDescription)")
            }
        }
    }
}
