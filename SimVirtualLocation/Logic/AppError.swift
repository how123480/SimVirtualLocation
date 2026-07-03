//
//  AppError.swift
//  SimVirtualLocation
//
//  Typed error model. Every fallible operation in MobileDeviceClient / Runner
//  surfaces one of these cases so that ErrorHandler can decide whether to
//  log, alert, or reset application state.
//

import Foundation

enum AppError: Error {

    // MARK: Tooling
    case pymobiledevice3NotInstalled
    case adbNotConfigured

    // MARK: Tunneld
    case tunneldAuthorizationCancelled
    case tunneldAuthorizationFailed(String)
    case tunneldFailedToStart(String)
    case tunneldNotReady

    // MARK: Device
    case deviceNotSelected
    case deviceLocked
    case developerModeDisabled
    case noBootedSimulators
    case noRouteToHost
    case tunnelConnectionLost(String)
    case mountFailed(String)
    case alreadyMounted

    // MARK: Command execution
    case processFailed(command: String, stderr: String)
    case commandTimedOut(command: String, seconds: Int)
    case invalidCoordinate

    // MARK: Suppressed
    case harmlessWarning(String)
}

extension AppError {

    enum Context {
        case setLocation
        case playGPX
        case clearLocation
        case mount
        case listDevices
        case tunneldStart
        case checkDeveloperMode

        var label: String {
            switch self {
            case .setLocation:         return "simulate-location set"
            case .playGPX:             return "simulate-location play"
            case .clearLocation:       return "simulate-location clear"
            case .mount:               return "mounter auto-mount"
            case .listDevices:         return "usbmux list"
            case .tunneldStart:        return "remote tunneld"
            case .checkDeveloperMode:  return "amfi developer-mode-status"
            }
        }
    }

    /// User-facing one-line message.
    var userMessage: String {
        switch self {
        case .pymobiledevice3NotInstalled:
            return "Could not find pymobiledevice3, please install it and retry (pip install pymobiledevice3)"
        case .adbNotConfigured:
            return "ADB path or device ID is not set"
        case .tunneldAuthorizationCancelled:
            return "Tunnel authorization cancelled"
        case .tunneldAuthorizationFailed(let m):
            return "Tunnel authorization failed: \(m)"
        case .tunneldFailedToStart(let m):
            return "Failed to start tunneld: \(m)"
        case .tunneldNotReady:
            return "Tunneld did not become ready within 30 s. Check that the device is unlocked and Developer Mode is enabled."
        case .deviceNotSelected:
            return "Device not selected"
        case .deviceLocked:
            return "Device is locked. Please unlock and retry."
        case .developerModeDisabled:
            return "Developer Mode is disabled on the device"
        case .noBootedSimulators:
            return "No booted simulators found"
        case .noRouteToHost:
            return "Tunnel disconnected (No route to host). Please restart the device connection."
        case .tunnelConnectionLost(let m):
            return "Tunnel connection lost: \(m)"
        case .mountFailed(let m):
            return "Mount Developer Image failed: \(m)"
        case .alreadyMounted:
            return "Developer Image is already mounted"
        case .processFailed(let cmd, let stderr):
            return "[\(cmd)] failed: \(stderr)"
        case .commandTimedOut(let cmd, let secs):
            return "[\(cmd)] timed out after \(secs)s"
        case .invalidCoordinate:
            return "Coordinate format error"
        case .harmlessWarning(let m):
            return m
        }
    }

    /// True for errors whose recovery requires wiping simulation state
    /// (annotations, overlays, timers, GPX playback).
    var requiresStateReset: Bool {
        if case .noRouteToHost = self { return true }
        return false
    }

    /// True when the error indicates the RSD tunnel to the device has dropped
    /// (rather than a logical failure). Callers use this to trigger silent
    /// tunnel recovery before giving up. Centralised here so the heuristic
    /// lives in one place instead of scattered string comparisons.
    var isTunnelDrop: Bool {
        switch self {
        case .noRouteToHost, .tunneldNotReady, .tunnelConnectionLost, .commandTimedOut:
            return true
        default:
            return false
        }
    }

    /// False when the error is informational and should not interrupt the user.
    var shouldShowAlert: Bool {
        switch self {
        case .harmlessWarning, .tunneldAuthorizationCancelled, .alreadyMounted:
            return false
        default:
            return true
        }
    }

    /// Classify a process stderr blob into the most specific known case.
    static func from(stderr: Data, context: Context) -> AppError {
        let text = String(decoding: stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if text.isEmpty {
            return .processFailed(command: context.label, stderr: "(empty)")
        }
        if text.contains("NotOpenSSLWarning") ||
           text.contains("urllib3 v2 only supports OpenSSL") ||
           text.contains("LibreSSL") {
            return .harmlessWarning(text)
        }
        if text.contains("No route to host") {
            return .noRouteToHost
        }
        let lower = text.lowercased()
        let tunnelDropPatterns = [
            "connection refused",
            "connectionreseterror",
            "connectionabortederror",
            "broken pipe",
            "errno 61",
            "errno 54",
            "errno 32",
            "failed to connect to tunneld",
            "tunneld is not running",
            "device is not connected",
        ]
        if tunnelDropPatterns.contains(where: { lower.contains($0) }) {
            let firstLine = text.components(separatedBy: .newlines).first ?? text
            return .tunnelConnectionLost(firstLine)
        }
        if text.range(of: "DeviceLocked", options: .caseInsensitive) != nil {
            return .deviceLocked
        }
        if text.range(of: "already mounted", options: .caseInsensitive) != nil ||
           text.range(of: "Image is already mounted", options: .caseInsensitive) != nil {
            return .alreadyMounted
        }
        return .processFailed(command: context.label, stderr: text)
    }
}
