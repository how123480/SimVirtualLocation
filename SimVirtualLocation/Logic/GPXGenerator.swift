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

    /// Endpoint information, describing which iOS device to send the GPX to.
    enum Endpoint: Equatable {
        case legacy(udid: String)
        case rsd(udid: String, address: String, port: String)
    }

    // MARK: - Public

    private(set) var currentGPXURL: URL?
    private(set) var endpoint: Endpoint?

    /// Whether a playback task is currently in progress
    var isPlaying: Bool { task != nil }

    // MARK: - Private

    private let runner: Runner
    private let logger = AppLogger.shared
    private var task: Task<Void, Never>?

    // MARK: - Init

    init(runner: Runner) {
        self.runner = runner
    }

    // MARK: - Public Methods

    /// Starts GPX playback (stops the previous one first).
    /// - Parameters:
    ///   - gpxURL: The GPX file to play
    ///   - endpoint: legacy / rsd
    ///   - alert: Closure to show alert if pymobiledevice3 fails to start
    func start(
        gpxURL: URL,
        endpoint: Endpoint,
        alert: @escaping (String) -> Void
    ) async {
        await stop()

        currentGPXURL = gpxURL
        self.endpoint = endpoint
        logger.info("Start GPX playback: \(gpxURL.lastPathComponent), endpoint=\(endpoint.label)")

        let runner = self.runner
        task = Task {
            do {
                switch endpoint {
                case .legacy(let udid):
                    try await runner.playGPXLegacy(udid: udid, gpxURL: gpxURL, showAlert: alert)
                case .rsd(let udid, let addr, let port):
                    try await runner.playGPXRSD(
                        udid: udid,
                        gpxURL: gpxURL,
                        RSDAddress: addr,
                        RSDPort: port,
                        showAlert: alert
                    )
                }
            } catch {
                AppLogger.shared.warn("GPX playback ended with error: \(error.localizedDescription)")
            }
        }
    }

    /// Stops current playback and clears state.
    func stop() async {
        let previous = task
        task = nil
        currentGPXURL = nil
        endpoint = nil
        previous?.cancel()
        await runner.stopCurrentTask()
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
