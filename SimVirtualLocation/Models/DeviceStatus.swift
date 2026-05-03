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
    case idle      // Not simulating
    case route     // Simulating along route
    case fromAToB  // Simulating straight line from A to B
    case mocking   // Fixed single point (location sent to device)

    var displayText: String {
        switch self {
        case .idle:     return "Not simulating"
        case .route:    return "Stop route simulation"
        case .fromAToB: return "Stop A→B simulation"
        case .mocking:  return "Mocking"
        }
    }

    /// String for the "Start" button
    var startButtonText: String {
        switch self {
        case .idle, .mocking: return "Simulate Route"
        case .route:          return "Stop Simulation"
        case .fromAToB:       return "Stop A→B Simulation"
        }
    }

    /// Whether location is being continuously changed (Route, A->B, and Single Point are all considered active)
    var isMockingActive: Bool {
        return self != .idle
    }
}
