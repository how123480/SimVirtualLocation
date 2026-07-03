//
//  Runner.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 19.05.2022.
//
//  External command executor for the Simulator path.
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

}
