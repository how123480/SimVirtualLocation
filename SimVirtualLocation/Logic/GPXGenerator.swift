//
//  GPXGenerator.swift
//  SimVirtualLocation
//
//  GPX route generator and playback controller.
//  - GPXGenerator: Pure data utility. Converts polyline + speed (km/h) into GPX files playable by pymobiledevice3,
//    and saves them to ~/Library/Application Support/SimVirtualLocation/routes/.
//  - GPXPlayback: @MainActor wrapper responsible for calling pymobiledevice3 `developer simulate-location play`,
//    managing lifecycle (start / stop), and exposing endpoint information so LocationController can regenerate GPX when speed dynamically changes.
//

import Foundation
import CoreLocation
import MapKit

// MARK: - GPXGenerator

enum GPXGenerator {

    /// GPX sampling interval (seconds). The <time> gap between each trkpt is fixed to this value,
    /// pymobiledevice3 plays at this pace, so actual speed = sampling distance / sampleInterval.
    static let sampleInterval: TimeInterval = 1.0

    /// GPX output directory (~/Library/Application Support/SimVirtualLocation/routes)
    static var outputDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return base.appendingPathComponent("SimVirtualLocation/routes", isDirectory: true)
    }

    // MARK: Public

    /// Comprehensive: Sample -> Generate XML -> Write File.
    /// - Parameters:
    ///   - polyline: Polyline with at least 2 coordinates
    ///   - speedKmh: Simulation speed (km/h)
    ///   - name: Filename (without extension); UUID recommended for debugging
    /// - Returns: The URL of the written GPX file
    @discardableResult
    static func render(
        polyline: [CLLocationCoordinate2D],
        speedKmh: Double,
        name: String
    ) throws -> URL {
        let sampled = samplePoints(polyline: polyline, speedKmh: speedKmh)
        let xml = makeXML(points: sampled)
        return try write(xml, name: name)
    }

    /// Samples along the polyline at fixed distances of "speed * sampleInterval".
    /// The first point is fixed as the start, and the last point is fixed as the end.
    static func samplePoints(
        polyline: [CLLocationCoordinate2D],
        speedKmh: Double
    ) -> [CLLocationCoordinate2D] {
        guard polyline.count >= 2 else { return polyline }
        let speedMps = max(speedKmh, 1.0) / 3.6
        let stepDistance = max(speedMps * sampleInterval, 0.5)

        var samples: [CLLocationCoordinate2D] = [polyline[0]]
        var nextSampleAt = stepDistance       // Accumulated distance from start for the next sample point
        var distanceFromStart: Double = 0     // Current accumulated distance of the prev point from the start
        var prev = polyline[0]

        for i in 1..<polyline.count {
            let cur = polyline[i]
            let segLen = CLLocation.distance(from: prev, to: cur)
            if segLen <= 0 {
                prev = cur
                continue
            }
            let segStart = distanceFromStart
            let segEnd = distanceFromStart + segLen
            while nextSampleAt <= segEnd {
                let f = (nextSampleAt - segStart) / segLen
                samples.append(.init(
                    latitude: prev.latitude + (cur.latitude - prev.latitude) * f,
                    longitude: prev.longitude + (cur.longitude - prev.longitude) * f
                ))
                nextSampleAt += stepDistance
            }
            distanceFromStart = segEnd
            prev = cur
        }

        // Ensure the polyline endpoint is included (prevents premature GPX termination)
        if let last = samples.last,
           let realEnd = polyline.last,
           CLLocation.distance(from: last, to: realEnd) > 0.5 {
            samples.append(realEnd)
        }
        return samples
    }

    /// Generates GPX 1.1 XML compatible with pymobiledevice3 parsing
    static func makeXML(
        points: [CLLocationCoordinate2D],
        startTime: Date = Date()
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="SimVirtualLocation" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>SimVirtualLocation Route</name>
            <trkseg>

        """
        for (i, p) in points.enumerated() {
            let t = startTime.addingTimeInterval(Double(i) * sampleInterval)
            xml += "      <trkpt lat=\"\(p.latitude)\" lon=\"\(p.longitude)\">"
            xml += "<time>\(formatter.string(from: t))</time></trkpt>\n"
        }
        xml += """
            </trkseg>
          </trk>
        </gpx>
        """
        return xml
    }

    /// Writes the GPX content to outputDirectory/<name>.gpx
    @discardableResult
    static func write(_ xml: String, name: String) throws -> URL {
        let dir = outputDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).gpx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Removes old GPX files beyond 50 to prevent infinite accumulation. Preserves the most recently modified.
    static func pruneOldFiles(keep: Int = 50) {
        let dir = outputDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let sorted = urls
            .filter { $0.pathExtension == "gpx" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l > r
            }
        guard sorted.count > keep else { return }
        for url in sorted.dropFirst(keep) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - GPXPlayback

/// pymobiledevice3 GPX playback lifecycle manager.
/// Maintains the current running Task internally; calling start automatically stops the previous task.
@MainActor
final class GPXPlayback {

    enum Endpoint: Equatable {
        case legacy(udid: String)
        case rsd(udid: String)
    }

    // MARK: - Public

    private(set) var currentGPXURL: URL?
    private(set) var endpoint: Endpoint?
    var isPlaying: Bool { handle?.isRunning ?? false }

    /// Called on the main actor when the current play process dies without
    /// stop() having been requested (tunnel drop, crash, early natural end).
    /// Wired once by LocationController.
    var onUnexpectedExit: ((Int32) -> Void)?

    // MARK: - Private

    private let client: MobileDeviceClient
    private let logger = AppLogger.shared
    private var handle: ProcessRunner.LongRunningHandle?

    /// Monotonic start counter. Every start() claims a new generation; any
    /// suspension point re-checks it so a superseded start can never install
    /// its (stale) process as the current one — at most one live play process.
    private var startGeneration = 0

    // MARK: - Init

    init(client: MobileDeviceClient) {
        self.client = client
    }

    // MARK: - Public Methods

    func start(gpxURL: URL,
               endpoint: Endpoint,
               alert: @escaping (String) -> Void) async {
        startGeneration += 1
        let generation = startGeneration

        await stop()
        guard generation == startGeneration else { return }

        currentGPXURL = gpxURL
        self.endpoint = endpoint
        logger.info("Start GPX playback: \(gpxURL.lastPathComponent), endpoint=\(endpoint.label)")

        let transport: MobileDeviceClient.Transport
        switch endpoint {
        case .legacy(let u): transport = .legacy(udid: u)
        case .rsd(let u):    transport = .rsd(udid: u)
        }

        do {
            let newHandle = try await client.playGPX(gpxURL, transport: transport) { [weak self] exitCode in
                Task { @MainActor [weak self] in
                    self?.handleTermination(generation: generation, exitCode: exitCode)
                }
            }
            guard generation == startGeneration else {
                await newHandle.stop()
                return
            }
            handle = newHandle
        } catch {
            alert((error as? AppError)?.userMessage ?? error.localizedDescription)
        }
    }

    func stop() async {
        let previous = handle
        handle = nil
        currentGPXURL = nil
        endpoint = nil
        await previous?.stop()
    }

    // MARK: - Private Methods

    private func handleTermination(generation: Int, exitCode: Int32) {
        // Superseded generations were stopped deliberately during a restart;
        // stop() nils the handle before signalling, so both guards below
        // filter intentional teardown.
        guard generation == startGeneration,
              let current = handle,
              !current.wasStoppedIntentionally else { return }
        handle = nil
        logger.warn("GPX play process exited unexpectedly (code \(exitCode))")
        onUnexpectedExit?(exitCode)
    }
}

private extension GPXPlayback.Endpoint {
    var label: String {
        switch self {
        case .legacy: return "legacy"
        case .rsd:    return "RSD"
        }
    }
}
