//
//  Runner.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 19.05.2022.
//
//  External command executor for the Simulator / Android paths.
//  iOS physical devices go through MobileDeviceClient; one-shot commands here
//  reuse ProcessRunner.execute so every child process gets the same safety
//  pattern (handler-before-launch, concurrent pipe drain, hard timeout).
//

import Foundation
import CoreLocation

class Runner {

    // MARK: - Public Properties

    /// Minimum interval (seconds) between location updates during route simulation
    var timeDelay: TimeInterval = 0.5

    // MARK: - Private Properties

    private let log = AppLogger.shared

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
        let args: [String]
        if isEmulator {
            args = [
                "-s", adbDeviceId,
                "emu", "geo", "fix",
                "\(location.longitude)",
                "\(location.latitude)",
            ]
        } else {
            args = [
                "-s", adbDeviceId,
                "shell", "am", "broadcast",
                "-a", "send.mock",
                "-e", "lat", "\(location.latitude)",
                "-e", "lon", "\(location.longitude)",
            ]
        }

        log.info("Android location: lat=\(location.latitude), lng=\(location.longitude)")
        log.debug("Android command: \(Sanitizer.sanitize(adbPath + " " + args.joined(separator: " ")))")

        do {
            let result = try await ProcessRunner.execute(executable: adbPath, args: args, timeout: 15)
            let err = String(decoding: result.stderr, as: UTF8.self)
            if !err.isEmpty {
                showAlert(err)
                log.error("Android stderr: \(err)")
            }
        } catch {
            showAlert(error.localizedDescription)
            log.error("Android command failed: \(error.localizedDescription)")
        }
    }
}
