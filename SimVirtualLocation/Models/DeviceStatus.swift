//
//  DeviceStatus.swift
//  SimVirtualLocation
//
//  Consolidates scattered string states from LocationController into strongly typed enums,
//  allowing the UI to directly display corresponding localized strings and avoid typos.
//

import Foundation

// MARK: - Device Connection Status

enum DeviceStatus: Equatable {
    case idle                   // Not started
    case checkingDeveloperMode  // Checking Developer Mode
    case waitingAuthorization   // Waiting for sudo authorization
    case mounting               // Mounting Developer Image
    case connecting             // Tunnel establishing
    case connected              // Connected
    case reconnecting           // Tunnel dropped; attempting silent recovery
    case error(String)          // Failed (including reason)

    /// String displayed next to the button
    var displayText: String {
        switch self {
        case .idle:                  return ""
        case .checkingDeveloperMode: return "Checking Developer Mode..."
        case .waitingAuthorization:  return "Waiting for authorization..."
        case .mounting:              return "Mounting..."
        case .connecting:            return "Connecting..."
        case .connected:             return "Connected"
        case .reconnecting:          return "Reconnecting…"
        case .error(let msg):        return "Error: \(msg)"
        }
    }

    /// Whether considered "device started"
    var isActive: Bool {
        switch self {
        case .idle, .error: return false
        default:            return true
        }
    }

    /// Whether location commands can be sent
    var isReady: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - Simulation Status

enum SimulationStatus: Equatable {
    case idle             // Not simulating
    case route            // Simulating along route
    case fromAToB         // Simulating straight line from A to B
    case routePaused      // Route simulation paused; puck frozen, device location held
    case fromAToBPaused   // A→B simulation paused; puck frozen, device location held
    case mocking          // Fixed single point (location sent to device)
    case stopping         // Async teardown in progress; button is greyed out

    var displayText: String {
        switch self {
        case .idle:           return "Not simulating"
        case .route:          return "Stop route simulation"
        case .fromAToB:       return "Stop A→B simulation"
        case .routePaused:    return "Route paused"
        case .fromAToBPaused: return "A→B paused"
        case .mocking:        return "Mocking"
        case .stopping:       return "Stopping…"
        }
    }

    /// String for the "Start" button
    var startButtonText: String {
        switch self {
        case .idle, .mocking:              return "Simulate Route"
        case .route, .routePaused:         return "Stop Simulation"
        case .fromAToB, .fromAToBPaused:   return "Stop A→B Simulation"
        case .stopping:                    return "Stopping…"
        }
    }

    /// Whether the simulation owns the device's location (so stopSimulation
    /// should run, joystick overrides apply, etc.). Paused states still own
    /// the location — the device sits at the last fix until stopped or resumed.
    /// .stopping is NOT mocking-active so the idempotent guard in
    /// stopSimulation() works (a second call early-returns).
    var isMockingActive: Bool {
        switch self {
        case .route, .fromAToB, .routePaused, .fromAToBPaused, .mocking: return true
        case .idle, .stopping:                                           return false
        }
    }

    /// True for paused-route states; UI uses this to flip pause↔resume icons.
    var isPaused: Bool {
        self == .routePaused || self == .fromAToBPaused
    }
}
