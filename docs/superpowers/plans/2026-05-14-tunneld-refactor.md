# tunneld-based daemon + Refactor + Stopping UX — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor pymobiledevice3 access through a single `MobileDeviceClient` abstraction, eliminate the per-Start/per-Stop password prompts by switching iOS 17+ from `start-tunnel + --rsd` to the long-lived `pymobiledevice3 remote tunneld` daemon, introduce typed `AppError` + centralized `ErrorHandler`, and add a `Stopping…` disabled state on the Stop button.

**Architecture:** Per the design spec at `docs/superpowers/specs/2026-05-14-tunneld-refactor-design.md`. New files: `AppError.swift`, `ErrorHandler.swift`, `MobileDeviceClient.swift`. `Runner.swift` shrinks to Android + Simulator only. `LocationController.swift` loses all RSD glue code, and `stopSimulation` becomes `async` + idempotent.

**Tech Stack:** Swift 5 / SwiftUI macOS 11+ app, `Process` async wrapping (no `DispatchQueue`, no `print`), `pymobiledevice3 remote tunneld` daemon, `NSAppleScript ... with administrator privileges` for the one-time root launch.

**Verification approach:** Project has no unit-test framework (per spec §3). Every behaviour-changing task ends with a `xcodebuild ... build CODE_SIGNING_ALLOWED=NO` and (where applicable) a regression-matrix entry from spec §11 walked through manually. Build command throughout:

```bash
xcodebuild -project SimVirtualLocation.xcodeproj \
  -scheme SimVirtualLocation \
  -configuration Debug \
  -destination 'platform=macOS' \
  build \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```

Expected on success: `** BUILD SUCCEEDED **`.

---

## Task 1: Add AppError enum

**Files:**
- Create: `SimVirtualLocation/Logic/AppError.swift`

- [ ] **Step 1: Create the file with full enum + extension**

Path: `SimVirtualLocation/Logic/AppError.swift`

```swift
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
    case mountFailed(String)
    case alreadyMounted

    // MARK: Command execution
    case processFailed(command: String, stderr: String)
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
        case .mountFailed(let m):
            return "Mount Developer Image failed: \(m)"
        case .alreadyMounted:
            return "Developer Image is already mounted"
        case .processFailed(let cmd, let stderr):
            return "[\(cmd)] failed: \(stderr)"
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
```

- [ ] **Step 2: Add file to Xcode project**

```bash
# Open the project and drag AppError.swift into the Logic group, or:
# (Most reliable) Open SimVirtualLocation.xcodeproj in Xcode, right-click
# Logic group → "Add Files to SimVirtualLocation…" → select AppError.swift.
```

If the project uses a `project.pbxproj`-only setup without folder synchronization, the file must be referenced in `project.pbxproj`. Verify with:

```bash
grep -c "AppError.swift" SimVirtualLocation.xcodeproj/project.pbxproj
```

Expected: at least 2 references (one for the file, one for the build phase).

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project SimVirtualLocation.xcodeproj -scheme SimVirtualLocation -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add SimVirtualLocation/Logic/AppError.swift SimVirtualLocation.xcodeproj/project.pbxproj
git commit -m "refactor(error): introduce AppError typed-error enum

No behaviour change. Adds AppError + Context classifier so future
ErrorHandler can centralise stderr-to-error translation."
```

---

## Task 2: Add ErrorHandler

**Files:**
- Create: `SimVirtualLocation/Logic/ErrorHandler.swift`

- [ ] **Step 1: Create ErrorHandler**

Path: `SimVirtualLocation/Logic/ErrorHandler.swift`

```swift
//
//  ErrorHandler.swift
//  SimVirtualLocation
//
//  Single funnel for application errors. Decides:
//    - Whether to write a log entry (always).
//    - Whether to wipe simulation state (AppError.requiresStateReset).
//    - Whether to surface an alert to the user (AppError.shouldShowAlert).
//

import Foundation

@MainActor
protocol ErrorHandlerHost: AnyObject {
    func resetAllState()
    func presentAlert(message: String)
}

@MainActor
final class ErrorHandler {

    // MARK: - Private Properties

    private weak var host: ErrorHandlerHost?
    private let logger = AppLogger.shared

    // MARK: - Init

    init(host: ErrorHandlerHost) {
        self.host = host
    }

    // MARK: - Public Methods

    func handle(_ error: Error, context: String = #function) {
        let appError = Self.normalize(error)
        logger.error("[\(context)] \(appError)")

        if appError.requiresStateReset {
            host?.resetAllState()
        }
        if appError.shouldShowAlert {
            host?.presentAlert(message: appError.userMessage)
        }
    }

    // MARK: - Private Methods

    private static func normalize(_ error: Error) -> AppError {
        if let appError = error as? AppError {
            return appError
        }
        return .processFailed(command: "unknown", stderr: error.localizedDescription)
    }
}
```

- [ ] **Step 2: Reference file in pbxproj (same procedure as Task 1)**

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project SimVirtualLocation.xcodeproj -scheme SimVirtualLocation -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```

Expected: `** BUILD SUCCEEDED **`.

(The project will not yet implement `ErrorHandlerHost` — that's added in Task 3. As long as `ErrorHandler` itself compiles, this task is done.)

- [ ] **Step 4: Commit**

```bash
git add SimVirtualLocation/Logic/ErrorHandler.swift SimVirtualLocation.xcodeproj/project.pbxproj
git commit -m "refactor(error): add ErrorHandler funnel

Routes AppError through log + optional state reset + optional alert.
Wiring into LocationController happens in the next commit."
```

---

## Task 3: Wire ErrorHandler into LocationController (behaviour-preserving)

**Files:**
- Modify: `SimVirtualLocation/Logic/LocationController.swift`

Strategy: add the new pieces without removing anything yet. `showAlert(_:)` keeps its existing string-matching logic. We just add a parallel `errorHandler` property and the `ErrorHandlerHost` conformance so future tasks can migrate call sites incrementally.

- [ ] **Step 1: Add ErrorHandlerHost conformance + helper methods**

Open `SimVirtualLocation/Logic/LocationController.swift`.

Locate the class declaration on line 20:

```swift
class LocationController: NSObject, ObservableObject, MKMapViewDelegate, CLLocationManagerDelegate, MKLocalSearchCompleterDelegate {
```

Replace with:

```swift
class LocationController: NSObject, ObservableObject, MKMapViewDelegate, CLLocationManagerDelegate, MKLocalSearchCompleterDelegate, ErrorHandlerHost {
```

- [ ] **Step 2: Add the errorHandler property**

In the `// MARK: - Private` section near line 137-146 where other private state lives, add after `private let logger = AppLogger.shared`:

```swift
    private lazy var errorHandler: ErrorHandler = ErrorHandler(host: self)
```

- [ ] **Step 3: Add resetAllState and presentAlert methods**

At the end of the class body (just before the final `}` on line 1189), add:

```swift
    // MARK: - ErrorHandlerHost

    func resetAllState() {
        deviceStatus = .idle
        simulationStatus = .idle

        mapView.mkMapView.removeOverlays(mapView.mkMapView.overlays)
        mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
        annotations = []
        route = nil
        tracks = []
        currentPolyline = []

        timer?.invalidate()
        timer = nil
        pendingSpeedRegenTask?.cancel()
        pendingSpeedRegenTask = nil

        Task {
            await gpxPlayback.stop()
            await runner.stopCurrentTask()
        }

        killRSDTunnel(for: selectedDevice)
    }

    func presentAlert(message: String) {
        alertText = message
        showingAlert = true
        simulationStatus = .idle
    }
```

(`resetAllState` lifts the inline block currently inside `showAlert(_:)` lines 793–818. We are NOT removing the inline block yet — Task 4 does that.)

- [ ] **Step 4: Build**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add SimVirtualLocation/Logic/LocationController.swift
git commit -m "refactor(error): wire ErrorHandler into LocationController

Adds errorHandler property, ErrorHandlerHost conformance, and helper
methods (resetAllState, presentAlert). Existing showAlert(_:) flow
is unchanged; migration of call sites happens next."
```

---

## Task 4: Migrate showAlert no-route-to-host block to ErrorHandler

**Files:**
- Modify: `SimVirtualLocation/Logic/LocationController.swift` (around lines 787–824)

- [ ] **Step 1: Replace the inline reset block**

In `LocationController.swift`, find `func showAlert(_ text: String) {` (line ~787) and replace the entire body of the method with:

```swift
    func showAlert(_ text: String) {
        // Map known textual patterns to AppError and funnel through ErrorHandler.
        // Anything unrecognised is wrapped as .processFailed with empty cmd label.
        if text.contains("No route to host") {
            errorHandler.handle(AppError.noRouteToHost)
            return
        }

        // Default path: surface the message without state reset.
        // (Equivalent to AppError.processFailed with default classification.)
        presentAlert(message: text)
        logger.warn("Alert: \(text)")
    }
```

The "No route to host" branch now goes through `errorHandler.handle(.noRouteToHost)`, which:
- Logs `[showAlert] noRouteToHost`.
- Calls `resetAllState()` because `noRouteToHost.requiresStateReset == true`.
- Calls `presentAlert(message: "Tunnel disconnected (No route to host)...")` because `shouldShowAlert == true`.

Behaviour equivalence vs. the old code:
- Old `simulationStatus = .idle` after alert → covered by `presentAlert` resetting it.
- Old `deviceStatus = .idle`, map cleanup, timer cancels, gpx stop, runner stop, killRSDTunnel → all in `resetAllState()`.
- Old "rephrase the message" → covered by `AppError.noRouteToHost.userMessage`.

- [ ] **Step 2: Build**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual regression — spec §11 scenario 9 (No route to host)**

This requires a physical iOS device. If unavailable, defer to the final regression pass in Task 19 and just verify build.

If available:
1. Connect iOS 17+ device, click Connect, click Start route.
2. Pull cable mid-route.
3. Observe alert "Tunnel disconnected (No route to host)..." appears.
4. Observe map is cleared, simulation status returns to idle, no orphan timer (re-Start works cleanly).

- [ ] **Step 4: Commit**

```bash
git add SimVirtualLocation/Logic/LocationController.swift
git commit -m "refactor(error): migrate No-route-to-host handling to ErrorHandler

The state-reset block formerly inlined in showAlert(_:) now lives in
ErrorHandler.handle / resetAllState. Behaviour preserved; call site
shrinks from ~30 lines to 6."
```

---

## Task 5: Create MobileDeviceClient skeleton + ProcessRunner

**Files:**
- Create: `SimVirtualLocation/Logic/MobileDeviceClient.swift`

- [ ] **Step 1: Create the skeleton**

Path: `SimVirtualLocation/Logic/MobileDeviceClient.swift`

```swift
//
//  MobileDeviceClient.swift
//  SimVirtualLocation
//
//  Single abstraction for all pymobiledevice3 access.
//  - iOS 16-: Transport.legacy(udid:) -> uses pymobiledevice3 developer simulate-location
//             with --udid; no tunnel, no root.
//  - iOS 17+: Transport.rsd(udid:) -> requires a running `pymobiledevice3 remote tunneld`
//             daemon. ensureTunneldRunning() launches it once (osascript admin) per Mac boot.
//             Subsequent commands use --udid only; tunneld auto-discovers the tunnel.
//
//  Owners and ownership:
//  - LocationController owns a single MobileDeviceClient instance.
//  - GPXPlayback (existing wrapper) is reworked to take a GPXPlaybackHandle from here.
//

import Foundation
import CoreLocation
import Combine

@MainActor
final class MobileDeviceClient: ObservableObject {

    // MARK: - Public Types

    enum TunneldStatus: Equatable {
        case idle
        case authorizing
        case launching
        case ready
        case failed(String)   // message only, for Equatable conformance
    }

    enum Transport: Equatable {
        case legacy(udid: String)
        case rsd(udid: String)

        var udid: String {
            switch self {
            case .legacy(let u), .rsd(let u): return u
            }
        }
    }

    enum MountResult { case mounted, alreadyMounted }

    // MARK: - Public State

    @Published private(set) var tunneldStatus: TunneldStatus = .idle

    // MARK: - Private Properties

    private let processRunner = ProcessRunner()
    private let logger = AppLogger.shared

    /// Currently running long-lived process (GPX play). At most one.
    private var currentLongRunning: ProcessRunner.LongRunningHandle?

    // MARK: - Init

    init() {}
}
```

- [ ] **Step 2: Append ProcessRunner internal struct in the same file**

Append below the `MobileDeviceClient` class:

```swift
// MARK: - ProcessRunner

/// Internal helper: wraps Process for one-shot and long-running pymobiledevice3 calls.
/// All path resolution and error mapping lives here so MobileDeviceClient methods
/// stay declarative.
struct ProcessRunner {

    struct ProcessResult {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
    }

    final class LongRunningHandle {
        let task: Process
        init(_ task: Process) { self.task = task }

        var isRunning: Bool { task.isRunning }

        func stop() async {
            guard task.isRunning else { return }
            task.terminate()
            let start = Date()
            while task.isRunning && Date().timeIntervalSince(start) < 2.0 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if task.isRunning {
                kill(task.processIdentifier, SIGKILL)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    // MARK: Lookup

    func locatePymobiledevice3() throws -> String {
        if let path = findExecutable("pymobiledevice3") { return path }
        throw AppError.pymobiledevice3NotInstalled
    }

    private func findExecutable(_ name: String) -> String? {
        let common = [
            "/Users/\(NSUserName())/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for p in common where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [
            "/Users/\(NSUserName())/.local/bin",
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/bin", "/bin",
            "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        task.environment = env
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let p = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (p?.isEmpty ?? true) ? nil : p
        } catch {
            return nil
        }
    }

    // MARK: One-shot

    func run(args: [String]) async throws -> ProcessResult {
        let task = try makeTask(args: args)
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardInput = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        try task.run()
        await waitExit(task)
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(exitCode: task.terminationStatus, stdout: out, stderr: err)
    }

    // MARK: Long-running (output discarded to avoid pipe buffer deadlock)

    func runDiscardingOutput(args: [String]) throws -> LongRunningHandle {
        let task = try makeTask(args: args)
        let devNull = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = devNull
        task.standardError = devNull
        try task.run()
        return LongRunningHandle(task)
    }

    // MARK: Helpers

    private func makeTask(args: [String]) throws -> Process {
        let path = try locatePymobiledevice3()
        let t = Process()
        t.executableURL = URL(fileURLWithPath: path)
        t.arguments = args
        return t
    }

    private func waitExit(_ task: Process) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            task.terminationHandler = { _ in cont.resume() }
        }
    }
}
```

- [ ] **Step 3: Reference file in pbxproj**

```bash
grep -c "MobileDeviceClient.swift" SimVirtualLocation.xcodeproj/project.pbxproj
```

Expected: ≥ 2 after adding via Xcode UI.

- [ ] **Step 4: Build**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add SimVirtualLocation/Logic/MobileDeviceClient.swift SimVirtualLocation.xcodeproj/project.pbxproj
git commit -m "refactor(client): add MobileDeviceClient skeleton + ProcessRunner

No call sites yet. Establishes Transport/TunneldStatus/MountResult types
and ProcessRunner helper. Migration of iOS device commands follows."
```

---

## Task 6: MobileDeviceClient — listDevices + Developer-Mode probes

**Files:**
- Modify: `SimVirtualLocation/Logic/MobileDeviceClient.swift`

- [ ] **Step 1: Add device-enumeration and developer-mode methods**

Inside the `MobileDeviceClient` class body, before the closing brace, add:

```swift
    // MARK: - Device discovery

    func listDevices() async throws -> [Device] {
        let result = try await processRunner.run(args: ["--no-color", "usbmux", "list"])
        if result.exitCode != 0 {
            throw AppError.from(stderr: result.stderr, context: .listDevices)
        }
        let devices = try JSONDecoder().decode([Device].self, from: result.stdout)
        var seen: Set<String> = []
        let unique = devices.filter { seen.insert($0.id).inserted }
        logger.info("Connected devices: \(unique.map { "\($0.name) (\($0.version))" }.joined(separator: ", "))")
        return unique
    }

    // MARK: - Developer Mode

    func checkDeveloperMode(udid: String) async throws -> Bool {
        let result = try await processRunner.run(args: ["amfi", "developer-mode-status", "--udid", udid])
        if result.exitCode != 0 {
            throw AppError.from(stderr: result.stderr, context: .checkDeveloperMode)
        }
        let text = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        logger.info("Developer Mode status: \(text)")
        return text.contains("true")
    }

    func revealDeveloperMode(udid: String) async throws {
        logger.info("Prompting device to open Developer Mode menu")
        _ = try await processRunner.run(args: ["amfi", "reveal-developer-mode", "--udid", udid])
        // reveal-developer-mode is best-effort; ignore exit code.
    }
```

- [ ] **Step 2: Build**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add SimVirtualLocation/Logic/MobileDeviceClient.swift
git commit -m "refactor(client): add device enumeration + dev-mode probes"
```

---

## Task 7: MobileDeviceClient — mountDeveloperImage

**Files:**
- Modify: `SimVirtualLocation/Logic/MobileDeviceClient.swift`

- [ ] **Step 1: Add mount method**

Inside the `MobileDeviceClient` class, append after `revealDeveloperMode`:

```swift
    // MARK: - Mount Developer Image

    func mountDeveloperImage(udid: String) async throws -> MountResult {
        let result = try await processRunner.run(args: ["mounter", "auto-mount", "--udid", udid])

        // pymobiledevice3 prints "already mounted" on stderr with non-zero exit;
        // treat that as success.
        if result.exitCode == 0 {
            return .mounted
        }
        let classified = AppError.from(stderr: result.stderr, context: .mount)
        if case .alreadyMounted = classified {
            logger.info("Developer Image already mounted on device")
            return .alreadyMounted
        }
        throw classified
    }
```

- [ ] **Step 2: Build**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add SimVirtualLocation/Logic/MobileDeviceClient.swift
git commit -m "refactor(client): add mountDeveloperImage with already-mounted handling"
```

---

## Task 8: MobileDeviceClient — setLocation / clearLocation / playGPX (both transports)

Both transports share the same `--udid` invocation — the only thing that differs is the subcommand path (`developer simulate-location` for legacy, `developer dvt simulate-location` for RSD).

**Files:**
- Modify: `SimVirtualLocation/Logic/MobileDeviceClient.swift`

- [ ] **Step 1: Add command helpers**

Inside `MobileDeviceClient` class, append after `mountDeveloperImage`:

```swift
    // MARK: - Location commands

    func setLocation(_ coord: CLLocationCoordinate2D, transport: Transport) async throws {
        if case .rsd = transport {
            try await ensureTunneldRunning()
        }
        let args = locationSetArgs(coord, transport: transport)
        let result = try await processRunner.run(args: args)
        try classifyResult(result, context: .setLocation)
    }

    func clearLocation(transport: Transport) async throws {
        if case .rsd = transport {
            try await ensureTunneldRunning()
        }
        let args = locationClearArgs(transport)
        let result = try await processRunner.run(args: args)
        try classifyResult(result, context: .clearLocation)
    }

    /// Plays GPX in the background. Returns a handle the caller stores.
    /// Calling stop() on the handle SIGTERMs the underlying process.
    func playGPX(_ url: URL, transport: Transport) async throws -> ProcessRunner.LongRunningHandle {
        if case .rsd = transport {
            try await ensureTunneldRunning()
        }
        // Stop any previously running long-running task first.
        await currentLongRunning?.stop()
        currentLongRunning = nil

        let args = locationPlayArgs(url, transport: transport)
        let handle = try processRunner.runDiscardingOutput(args: args)
        currentLongRunning = handle
        logger.info("Started GPX playback: \(url.lastPathComponent), transport=\(transport.label)")
        return handle
    }

    // MARK: - Argument builders

    private func locationSetArgs(_ c: CLLocationCoordinate2D, transport: Transport) -> [String] {
        let lat = String(format: "%.5f", c.latitude)
        let lng = String(format: "%.5f", c.longitude)
        switch transport {
        case .legacy(let udid):
            return ["developer", "simulate-location", "set",
                    "--udid", udid, "--", lat, lng]
        case .rsd(let udid):
            return ["developer", "dvt", "simulate-location", "set",
                    "--udid", udid, "--", lat, lng]
        }
    }

    private func locationClearArgs(_ transport: Transport) -> [String] {
        switch transport {
        case .legacy(let udid):
            return ["developer", "simulate-location", "clear", "--udid", udid]
        case .rsd(let udid):
            return ["developer", "dvt", "simulate-location", "clear", "--udid", udid]
        }
    }

    private func locationPlayArgs(_ url: URL, transport: Transport) -> [String] {
        switch transport {
        case .legacy(let udid):
            return ["developer", "simulate-location", "play",
                    "--udid", udid, url.path]
        case .rsd(let udid):
            return ["developer", "dvt", "simulate-location", "play",
                    "--udid", udid, url.path]
        }
    }

    private func classifyResult(_ result: ProcessRunner.ProcessResult,
                                context: AppError.Context) throws {
        // SIGTERM (15) is expected for our own teardown — not an error.
        if result.exitCode == 0 || result.exitCode == 15 { return }
        let classified = AppError.from(stderr: result.stderr, context: context)
        if case .harmlessWarning = classified { return }
        throw classified
    }
```

- [ ] **Step 2: Add a tunneld stub so the file compiles**

At end of the class, BEFORE the closing brace:

```swift
    // MARK: - Tunneld (full implementation in a later task)

    func ensureTunneldRunning() async throws {
        // Stub: full TunneldSupervisor lands in Task 10.
        // Until then, .rsd transport callers will fail with .tunneldNotReady,
        // which is exactly what we want — no live calls go through this path yet.
        if case .ready = tunneldStatus { return }
        throw AppError.tunneldNotReady
    }
```

- [ ] **Step 3: Add Transport.label helper**

Below the `enum Transport` declaration (which currently lives inside the class), inside that enum, add a private `label` computed property by replacing:

```swift
    enum Transport: Equatable {
        case legacy(udid: String)
        case rsd(udid: String)

        var udid: String {
            switch self {
            case .legacy(let u), .rsd(let u): return u
            }
        }
    }
```

with:

```swift
    enum Transport: Equatable {
        case legacy(udid: String)
        case rsd(udid: String)

        var udid: String {
            switch self {
            case .legacy(let u), .rsd(let u): return u
            }
        }

        var label: String {
            switch self {
            case .legacy: return "legacy"
            case .rsd:    return "rsd"
            }
        }
    }
```

- [ ] **Step 4: Build**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add SimVirtualLocation/Logic/MobileDeviceClient.swift
git commit -m "refactor(client): add set/clear/playGPX for both transports

RSD transport currently throws .tunneldNotReady because ensureTunneldRunning
is still a stub; LocationController call sites still go via Runner. Migration
of the legacy path is next; tunneld real implementation follows."
```

---

## Task 9: Migrate LocationController iOS-16 path through MobileDeviceClient

**Files:**
- Modify: `SimVirtualLocation/Logic/LocationController.swift`

We migrate ONLY the legacy (iOS 16-) path here. iOS 17+ keeps using the existing `runner` + `startRSDTunnel` until Task 11.

- [ ] **Step 1: Add the client property + currentTransport helper**

Open `LocationController.swift`. In the `// MARK: - Private` block (around line 137), below `private let runner = Runner()`, add:

```swift
    private let client = MobileDeviceClient()
```

In the same class, near `var isRouteSimulationActive` (around line 945), add:

```swift
    /// The transport to use for the currently selected device.
    /// Returns nil for non-iOS-device modes (Simulator / Android).
    private func currentTransport() -> MobileDeviceClient.Transport? {
        guard deviceType == 0, deviceMode == .device, !selectedDevice.isEmpty else { return nil }
        return useRSD ? .rsd(udid: selectedDevice) : .legacy(udid: selectedDevice)
    }
```

- [ ] **Step 2: Rewrite startDevice's legacy branch through client**

Find `func startDevice()` (line ~597). Replace its body with:

```swift
    func startDevice() {
        guard !selectedDevice.isEmpty else {
            showAlert("Device not selected")
            return
        }
        Task { @MainActor in
            self.deviceStatus = .checkingDeveloperMode
            do {
                let enabled = try await client.checkDeveloperMode(udid: selectedDevice)
                if !enabled {
                    try? await client.revealDeveloperMode(udid: selectedDevice)
                    self.deviceStatus = .idle
                    showAlert(Constants.developerModeInstructions)
                    return
                }
            } catch {
                self.deviceStatus = .idle
                errorHandler.handle(error)
                return
            }

            if useRSD {
                startRSDTunnel()           // unchanged for now; replaced in Task 11
            } else {
                await mountDeveloperImageThroughClient()
            }
        }
    }

    /// New helper used by both the iOS-16 legacy path and (later) anywhere that
    /// needs an explicit mount step.
    private func mountDeveloperImageThroughClient() async {
        do {
            self.deviceStatus = .mounting
            _ = try await client.mountDeveloperImage(udid: selectedDevice)
            self.deviceStatus = .connected
        } catch {
            self.deviceStatus = .idle
            errorHandler.handle(error)
        }
    }
```

- [ ] **Step 3: Rewrite the legacy iOS device branch in `run(location:)`**

Find inside `run(location:)` (line ~1111) the `// iOS Device` block (line ~1143):

```swift
        // iOS Device
        if deviceMode == .device {
            if useRSD {
                currentRunTask = Task { ...existing RSD path... }
            } else {
                currentRunTask = Task {
                    await runner.stopCurrentTask()
                    if Task.isCancelled { return }
                    try? await runner.runOnIos(
                        location: location,
                        udid: selectedDevice,
                        showAlert: weakAlert
                    )
                    if simulationStatus == .idle { simulationStatus = .mocking }
                }
            }
            return
        }
```

Replace the legacy branch only (`else { currentRunTask = Task { ... runOnIos ... } }`) with:

```swift
            } else {
                currentRunTask = Task {
                    if Task.isCancelled { return }
                    do {
                        try await client.setLocation(location, transport: .legacy(udid: selectedDevice))
                        if simulationStatus == .idle { simulationStatus = .mocking }
                    } catch {
                        errorHandler.handle(error)
                    }
                }
            }
```

Leave the `if useRSD { ... }` branch above this block UNCHANGED. It still uses `runner.runOnNewIos` and `startRSDTunnel`; we replace it in Task 11.

- [ ] **Step 4: Rewrite legacy iOS in `stopLegacyDevice`**

Find `private func stopLegacyDevice() async {` (line ~627). Replace body:

```swift
    private func stopLegacyDevice() async {
        simulationStatus = .idle
        do {
            try await client.clearLocation(transport: .legacy(udid: selectedDevice))
        } catch {
            errorHandler.handle(error)
        }

        mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
        annotations = []
        if let route { mapView.mkMapView.removeOverlay(route.polyline) }
        deviceStatus = .idle
    }
```

- [ ] **Step 5: Build**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Manual regression — spec §11 scenario 7 (iOS 16 device)**

If an iOS 16- device is available:
1. Connect device, select from dropdown.
2. Click Connect Device → should prompt for **no** password, mount succeeds.
3. Click Set Location at a point on the map → location set, no errors.
4. Click "Stop Device" / disconnect button → location cleared, idle.

If no iOS 16- device, defer to Task 19.

- [ ] **Step 7: Commit**

```bash
git add SimVirtualLocation/Logic/LocationController.swift
git commit -m "refactor(client): route iOS 16 legacy path through MobileDeviceClient

startDevice/run(location:)/stopLegacyDevice for the !useRSD case now use
MobileDeviceClient + ErrorHandler. iOS 17+ path remains on Runner +
startRSDTunnel until tunneld lands."
```

---

## Task 10: Add TunneldSupervisor

**Files:**
- Modify: `SimVirtualLocation/Logic/MobileDeviceClient.swift`

- [ ] **Step 1: Append TunneldSupervisor and full ensureTunneldRunning to the file**

Open `MobileDeviceClient.swift`. **Remove** the stub:

```swift
    func ensureTunneldRunning() async throws {
        // Stub: full TunneldSupervisor lands in Task 10.
        if case .ready = tunneldStatus { return }
        throw AppError.tunneldNotReady
    }
```

Add the real implementation. Inside `MobileDeviceClient` class, in place of the stub:

```swift
    // MARK: - Tunneld lifecycle

    private let tunneldHostURL = URL(string: "http://127.0.0.1:49151/")!

    func ensureTunneldRunning() async throws {
        if case .ready = tunneldStatus { return }

        if await TunneldSupervisor.isRunning() {
            logger.info("tunneld already running, polling for HTTP readiness")
            tunneldStatus = .launching
            try await TunneldSupervisor.waitForReady(url: tunneldHostURL, timeout: 30.0)
            tunneldStatus = .ready
            logger.info("tunneld is ready")
            return
        }

        // Need root authorization to launch.
        tunneldStatus = .authorizing
        do {
            try await TunneldSupervisor.launchAsRoot()
        } catch let err as AppError {
            tunneldStatus = .failed(err.userMessage)
            throw err
        }

        tunneldStatus = .launching
        do {
            try await TunneldSupervisor.waitForReady(url: tunneldHostURL, timeout: 30.0)
        } catch {
            tunneldStatus = .failed("Not ready within 30s")
            throw AppError.tunneldNotReady
        }
        tunneldStatus = .ready
        logger.info("tunneld launched and ready")
    }

    /// Manual-only. Not wired to any default UI affordance.
    func killTunneld() async throws {
        try await TunneldSupervisor.kill()
        tunneldStatus = .idle
    }
```

- [ ] **Step 2: Append TunneldSupervisor struct at the bottom of the file**

After `struct ProcessRunner { ... }`:

```swift
// MARK: - TunneldSupervisor

/// Static utility around the `pymobiledevice3 remote tunneld` daemon.
/// Lifecycle policy (per design spec §4):
///  - Liveness: pgrep for `pymobiledevice3 remote tunneld`.
///  - Readiness: HTTP GET 127.0.0.1:49151 returns 2xx.
///  - Launch: NSAppleScript "do shell script ... with administrator privileges"
///    runs the command as root in the background; survives the App quitting.
///  - Kill: NSAppleScript with admin privileges (also prompts for password).
enum TunneldSupervisor {

    private static let logger = AppLogger.shared

    static func isRunning() async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                task.arguments = ["-f", "pymobiledevice3 remote tunneld"]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = Pipe()
                do {
                    try task.run()
                    task.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let pids = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(returning: !pids.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } catch {
                    cont.resume(returning: false)
                }
            }
        }
    }

    /// Polls `url` until it returns 2xx. Throws AppError.tunneldNotReady on timeout.
    static func waitForReady(url: URL, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let pollInterval: UInt64 = 500_000_000   // 500 ms

        while Date() < deadline {
            if await isReachable(url: url) { return }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
        throw AppError.tunneldNotReady
    }

    private static func isReachable(url: URL) async -> Bool {
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        req.httpMethod = "GET"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return true
            }
        } catch {
            // Connection refused / unreachable → not ready yet.
        }
        return false
    }

    /// Launches `pymobiledevice3 remote tunneld` as root in the background.
    /// One osascript prompt fires here.
    static func launchAsRoot() async throws {
        guard let pmPath = findPymobiledevice3Path() else {
            throw AppError.pymobiledevice3NotInstalled
        }
        // Background `&` so the AppleScript completes immediately; tunneld stays alive.
        let shell = "\(pmPath) remote tunneld > /tmp/skywalker-tunneld.log 2>&1 &"
        let script = "do shell script \"sh -c '\(shell)'\" with administrator privileges"

        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        _ = appleScript?.executeAndReturnError(&errorDict)

        if let errorDict = errorDict {
            let msg = (errorDict[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
            if msg.contains("User canceled") {
                throw AppError.tunneldAuthorizationCancelled
            }
            throw AppError.tunneldAuthorizationFailed(msg)
        }
        logger.info("tunneld launched in background as root")
    }

    static func kill() async throws {
        let script = "do shell script \"pkill -f 'pymobiledevice3 remote tunneld'\" with administrator privileges"
        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        _ = appleScript?.executeAndReturnError(&errorDict)
        if let errorDict = errorDict {
            let msg = (errorDict[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
            if msg.contains("User canceled") {
                throw AppError.tunneldAuthorizationCancelled
            }
            throw AppError.tunneldAuthorizationFailed(msg)
        }
    }

    // MARK: Helpers

    private static func findPymobiledevice3Path() -> String? {
        let common = [
            "/Users/\(NSUserName())/.local/bin/pymobiledevice3",
            "/opt/homebrew/bin/pymobiledevice3",
            "/usr/local/bin/pymobiledevice3",
        ]
        return common.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
```

`NSAppleScript` requires `AppKit`. Open the file's import block at the top and add:

```swift
import AppKit
```

(if not already present.)

- [ ] **Step 3: Build**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add SimVirtualLocation/Logic/MobileDeviceClient.swift
git commit -m "refactor(client): add TunneldSupervisor (real ensureTunneldRunning)

Detects existing tunneld (pgrep), polls HTTP readiness on
http://127.0.0.1:49151/, and launches via NSAppleScript admin if not
running. Not yet wired into LocationController.startDevice."
```

---

## Task 11: Switch LocationController.startDevice's iOS-17+ branch to tunneld

**Files:**
- Modify: `SimVirtualLocation/Logic/LocationController.swift`

- [ ] **Step 1: Replace startRSDTunnel call in startDevice**

In `startDevice()` (modified in Task 9), find:

```swift
            if useRSD {
                startRSDTunnel()           // unchanged for now; replaced in Task 11
            } else {
                await mountDeveloperImageThroughClient()
            }
```

Replace the whole `if/else` with:

```swift
            if useRSD {
                await connectViaTunneld()
            } else {
                await mountDeveloperImageThroughClient()
            }
```

Then add the helper at the same indentation, below `mountDeveloperImageThroughClient`:

```swift
    private func connectViaTunneld() async {
        do {
            self.deviceStatus = .waitingAuthorization
            try await client.ensureTunneldRunning()
            self.deviceStatus = .connected
        } catch {
            self.deviceStatus = .idle
            errorHandler.handle(error)
        }
    }
```

Note: `deviceStatus = .waitingAuthorization` is briefly set so the UI shows the existing "Waiting for authorization" label while the osascript dialog is on screen. `MobileDeviceClient.tunneldStatus` is also being maintained in parallel; future UI work could read that directly, but for this refactor the existing `DeviceStatus` is sufficient.

- [ ] **Step 2: Rewrite iOS-17+ branch of `run(location:)` to use client**

Find inside `run(location:)`:

```swift
            if useRSD {
                currentRunTask = Task {
                    await runner.stopCurrentTask()
                    if Task.isCancelled { return }
                    try? await runner.runOnNewIos(
                        location: location,
                        udid: selectedDevice,
                        RSDAddress: RSDAddress,
                        RSDPort: RSDPort,
                        showAlert: weakAlert
                    )
                    if simulationStatus == .idle { simulationStatus = .mocking }
                }
            } else {
                currentRunTask = Task { ...legacy via client... }
            }
```

Replace the `if useRSD { ... }` branch with:

```swift
            if useRSD {
                currentRunTask = Task {
                    if Task.isCancelled { return }
                    do {
                        try await client.setLocation(location, transport: .rsd(udid: selectedDevice))
                        if simulationStatus == .idle { simulationStatus = .mocking }
                    } catch {
                        errorHandler.handle(error)
                    }
                }
            } else {
                /* legacy branch from Task 9 */
            }
```

- [ ] **Step 3: Rewrite `stopRSDTunnel` body**

Find `func stopRSDTunnel() async {` (line ~719). Replace body with:

```swift
    func stopRSDTunnel() async {
        simulationStatus = .idle
        do {
            try await client.clearLocation(transport: .rsd(udid: selectedDevice))
        } catch {
            errorHandler.handle(error)
        }

        mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
        annotations = []
        if let route { mapView.mkMapView.removeOverlay(route.polyline) }
        deviceStatus = .idle
        // tunneld stays alive across app launches.
    }
```

Note we deliberately do **not** kill tunneld here. Per design spec §2, tunneld persists until Mac reboot.

- [ ] **Step 4: Update GPXPlayback to use the client**

Open `SimVirtualLocation/Logic/GPXGenerator.swift`. Find the `GPXPlayback` class (line 161). Replace its body with:

```swift
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

    // MARK: - Private

    private let client: MobileDeviceClient
    private let logger = AppLogger.shared
    private var handle: ProcessRunner.LongRunningHandle?

    // MARK: - Init

    init(client: MobileDeviceClient) {
        self.client = client
    }

    // MARK: - Public Methods

    func start(gpxURL: URL,
               endpoint: Endpoint,
               alert: @escaping (String) -> Void) async {
        await stop()

        currentGPXURL = gpxURL
        self.endpoint = endpoint
        logger.info("Start GPX playback: \(gpxURL.lastPathComponent), endpoint=\(endpoint.label)")

        let transport: MobileDeviceClient.Transport
        switch endpoint {
        case .legacy(let u): transport = .legacy(udid: u)
        case .rsd(let u):    transport = .rsd(udid: u)
        }

        do {
            handle = try await client.playGPX(gpxURL, transport: transport)
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
}

private extension GPXPlayback.Endpoint {
    var label: String {
        switch self {
        case .legacy: return "legacy"
        case .rsd:    return "RSD"
        }
    }
}
```

Note `GPXPlayback.Endpoint.rsd` no longer carries `address:port`. Update its single construction site:

In `LocationController.swift`, find `currentGPXEndpoint()` (line ~955):

```swift
    private func currentGPXEndpoint() -> GPXPlayback.Endpoint? {
        guard !selectedDevice.isEmpty else { return nil }
        if useRSD {
            guard !RSDAddress.isEmpty, !RSDPort.isEmpty else { return nil }
            return .rsd(udid: selectedDevice, address: RSDAddress, port: RSDPort)
        }
        return .legacy(udid: selectedDevice)
    }
```

Replace body:

```swift
    private func currentGPXEndpoint() -> GPXPlayback.Endpoint? {
        guard !selectedDevice.isEmpty else { return nil }
        return useRSD ? .rsd(udid: selectedDevice) : .legacy(udid: selectedDevice)
    }
```

In `LocationController.swift` near line 141:

```swift
    private lazy var gpxPlayback = GPXPlayback(runner: runner)
```

Replace with:

```swift
    private lazy var gpxPlayback = GPXPlayback(client: client)
```

- [ ] **Step 5: Build**

Expected: `** BUILD SUCCEEDED **`.

If `Runner` references in `GPXPlayback` were the only reason `Runner.playGPXLegacy` / `Runner.playGPXRSD` existed, those will become dead code now — that's fine; Task 17 strips them.

- [ ] **Step 6: Manual regression — spec §11 scenarios 1, 2, 5, 6**

Requires an iOS 17+ device.

1. **(Scenario 1)** Reboot Mac. Open app. Select iOS 17+ device. Click Connect → expect one password prompt → connected.
2. **(Scenario 2)** Click Start route on a calculated route → puck moves, no second prompt.
3. **(Scenario 5)** Quit App → reopen → Connect → no prompt.
4. **(Scenario 6)** From terminal: `sudo pkill -f 'pymobiledevice3 remote tunneld'`. Reopen → Connect → prompt returns once → connected.

- [ ] **Step 7: Commit**

```bash
git add SimVirtualLocation/Logic/LocationController.swift SimVirtualLocation/Logic/GPXGenerator.swift
git commit -m "refactor(tunneld): switch iOS 17+ from start-tunnel+--rsd to tunneld

LocationController.startDevice/run(location:)/stopRSDTunnel and
GPXPlayback now use MobileDeviceClient. iOS 17+ commands use --udid
only; tunneld auto-discovers tunnels. One password prompt per Mac boot."
```

---

## Task 12: Remove RSD log monitoring code paths

These methods are now unreachable. Removing them shrinks `LocationController` and prevents drift.

**Files:**
- Modify: `SimVirtualLocation/Logic/LocationController.swift`

- [ ] **Step 1: Delete startRSDTunnel, monitorRSDLog, parseRSDOutput, killRSDTunnel**

In `LocationController.swift`, delete:
- `func startRSDTunnel()` (lines ~644–688)
- `private func monitorRSDLog(at path:)` (lines ~690–717)
- `private func killRSDTunnel(for udid:)` (lines ~739–743)
- `private func parseRSDOutput(_ output:)` (lines ~862–877)

Also remove the `killRSDTunnel(for:)` line inside `resetAllState()` (added in Task 3) — tunneld is deliberately persistent now:

```swift
        killRSDTunnel(for: selectedDevice)
```

→ delete this line.

- [ ] **Step 2: Remove RSDAddress / RSDPort properties**

Find lines ~92-93:

```swift
    @Published var RSDAddress: String = ""
    @Published var RSDPort: String = ""
```

Delete both.

- [ ] **Step 3: Build**

Expected: `** BUILD SUCCEEDED **`.

If the build fails with "Cannot find 'RSDAddress' in scope" the remaining offender is the View layer; note the file path and confirm it'll be fixed by Task 16.

If failure is in the View layer (LocationSettingsPanel.swift), you can either:
- (a) Skip ahead to Task 16 first, then return; or
- (b) Temporarily stub the properties (NOT recommended).

Preferred: confirm the only build break is `LocationSettingsPanel.swift`, then proceed to Task 16 immediately and treat 12+16 as one commit.

- [ ] **Step 4: Commit (alone if build is green, or combined with Task 16)**

```bash
git add SimVirtualLocation/Logic/LocationController.swift
git commit -m "refactor(tunneld): delete RSD log-monitoring code

startRSDTunnel/monitorRSDLog/parseRSDOutput/killRSDTunnel and the
@Published RSDAddress/RSDPort are gone. Tunneld is now persistent;
the App no longer parses 'RSD Address: ...' from stdout logs."
```

---

## Task 13: Add SimulationStatus.stopping

**Files:**
- Modify: `SimVirtualLocation/Models/DeviceStatus.swift`

- [ ] **Step 1: Read current SimulationStatus**

```bash
sed -n '1,200p' SimVirtualLocation/Models/DeviceStatus.swift
```

Locate `enum SimulationStatus`.

- [ ] **Step 2: Add the `.stopping` case + update its helpers**

In `enum SimulationStatus`, add a new case alongside existing ones:

```swift
enum SimulationStatus {
    case idle
    case route
    case fromAToB
    case mocking
    case stopping        // ← new
}
```

(Match the existing style of the file — if the cases are on a single line, add `stopping` to the same line.)

Update the `displayText` computed property. Find the existing switch and add:

```swift
        case .stopping: return "Stopping…"
```

Update `isMockingActive`:

```swift
    var isMockingActive: Bool {
        switch self {
        case .route, .fromAToB, .mocking: return true
        case .idle, .stopping:            return false
        }
    }
```

(`.stopping` is **not** mocking-active. That is what makes the idempotent guard in Task 14 work.)

- [ ] **Step 3: Build**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add SimVirtualLocation/Models/DeviceStatus.swift
git commit -m "feat(ui): add SimulationStatus.stopping transition state

Used by the in-flight Stop button. .stopping is NOT mocking-active,
giving stopSimulation() an idempotent guard."
```

---

## Task 14: Make stopSimulation async + idempotent

**Files:**
- Modify: `SimVirtualLocation/Logic/LocationController.swift`

- [ ] **Step 1: Convert `stopSimulation` to async**

Find `func stopSimulation(clearAnnotations: Bool = true) {` (line ~404). Replace the whole method with:

```swift
    func stopSimulation(clearAnnotations: Bool = true) async {
        // Idempotent: a second call while already stopping is a no-op.
        guard simulationStatus.isMockingActive else { return }
        simulationStatus = .stopping

        pendingSpeedRegenTask?.cancel()
        pendingSpeedRegenTask = nil
        timer?.invalidate()
        timer = nil

        await gpxPlayback.stop()

        // Clear any in-flight per-tick location task.
        currentRunTask?.cancel()
        currentRunTask = nil

        if let transport = currentTransport() {
            do {
                try await client.clearLocation(transport: transport)
            } catch {
                errorHandler.handle(error)
            }
        }

        mapView.mkMapView.removeOverlays(mapView.mkMapView.overlays)
        route = nil
        tracks = []
        currentPolyline = []

        if clearAnnotations {
            mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
            annotations = []
        }
        logger.info("Simulation stopped")
        simulationStatus = .idle
    }
```

- [ ] **Step 2: Update all internal `stopSimulation(clearAnnotations:)` call sites**

Search for callers (excluding the new definition):

```bash
grep -n 'stopSimulation' SimVirtualLocation/Logic/LocationController.swift
```

Each non-async caller needs wrapping. Specific edits:

(a) In `simulateFromAToB()` line ~336:
```swift
        stopSimulation(clearAnnotations: false)
```
Replace with:
```swift
        Task { await stopSimulation(clearAnnotations: false) }
```

Wait — this is a problem: `simulateFromAToB` builds tracks immediately *after* `stopSimulation`, expecting it to have run. We must await. Replace with:
```swift
        Task {
            await stopSimulation(clearAnnotations: false)
            // Reuse the rest of simulateFromAToB inside the Task so we run
            // after teardown completes.
        }
```

This is a refactor of the function. Replace the body of `simulateFromAToB` entirely with:

```swift
    func simulateFromAToB() {
        guard annotations.count == 2 else {
            showAlert("A->B simulation requires two points")
            return
        }
        let startPoint = annotations[0]
        let endPoint = annotations[1]

        Task { @MainActor in
            await stopSimulation(clearAnnotations: false)

            let polyline = MKPolyline(coordinates: [startPoint.coordinate, endPoint.coordinate], count: 2)
            mapView.mkMapView.addOverlay(polyline, level: .aboveRoads)

            tracks = [Track(startPoint: MKMapPoint(startPoint.coordinate), endPoint: MKMapPoint(endPoint.coordinate))]
            currentPolyline = [startPoint.coordinate, endPoint.coordinate]
            invalidateState()
            simulationStatus = .fromAToB
            startMovementTimer()
            kickoffGPXPlaybackIfNeeded()
        }
    }
```

(b) In `performMovement` line ~901:
```swift
            stopSimulation(clearAnnotations: false)
```
Replace with:
```swift
            Task { await stopSimulation(clearAnnotations: false) }
```

(c) In `handlePointsModeChange` line ~1071:
```swift
            stopSimulation(clearAnnotations: false)
```
Replace with:
```swift
            Task { await stopSimulation(clearAnnotations: false) }
```

- [ ] **Step 3: Build**

Expected: `** BUILD SUCCEEDED **`. Any `error: expression is 'async' but is not marked with 'await'` is a missed call site — track it down with `grep -n stopSimulation`.

- [ ] **Step 4: Commit**

```bash
git add SimVirtualLocation/Logic/LocationController.swift
git commit -m "feat(ui): make stopSimulation async + idempotent

Transitions through .stopping; subsequent calls early-return until
teardown completes. Internal callers wrap in Task { await ... }."
```

---

## Task 15: Update Stop buttons in LocationSettingsPanel

**Files:**
- Modify: `SimVirtualLocation/Views/LocationSettingsPanel.swift`

- [ ] **Step 1: Read the current Stop button definitions**

```bash
sed -n '90,120p' SimVirtualLocation/Views/LocationSettingsPanel.swift
```

There are two buttons (lines ~94–103 for Route, ~106–115 for A→B).

- [ ] **Step 2: Rewrite the Route Stop button**

Replace the existing Route button (around line 94):

```swift
                        Button(action: {
                            if locationController.simulationStatus == .route {
                                locationController.stopSimulation()
                            } else {
                                locationController.makeRoute(autoSimulate: true)
                            }
                        }) {
                            Text(locationController.simulationStatus == .route ? "Stop Simulation" : "Simulate Route")
                        }
```

With:

```swift
                        Button(action: {
                            if locationController.simulationStatus == .route {
                                Task { await locationController.stopSimulation() }
                            } else {
                                locationController.makeRoute(autoSimulate: true)
                            }
                        }) {
                            HStack(spacing: 4) {
                                if locationController.simulationStatus == .stopping {
                                    ProgressView().controlSize(.small)
                                    Text("Stopping…")
                                } else if locationController.simulationStatus == .route {
                                    Text("Stop Simulation")
                                } else {
                                    Text("Simulate Route")
                                }
                            }
                        }
                        .disabled(locationController.simulationStatus == .stopping)
```

- [ ] **Step 3: Rewrite the A→B Stop button**

Replace the existing A→B button (around line 106):

```swift
                        Button(action: {
                            if locationController.simulationStatus == .fromAToB {
                                locationController.stopSimulation()
                            } else {
                                locationController.simulateFromAToB()
                            }
                        }) {
                            Text(locationController.simulationStatus == .fromAToB ? "Stop A→B Simulation" : "A→B Linear Simulation")
                        }
```

With:

```swift
                        Button(action: {
                            if locationController.simulationStatus == .fromAToB {
                                Task { await locationController.stopSimulation() }
                            } else {
                                locationController.simulateFromAToB()
                            }
                        }) {
                            HStack(spacing: 4) {
                                if locationController.simulationStatus == .stopping {
                                    ProgressView().controlSize(.small)
                                    Text("Stopping…")
                                } else if locationController.simulationStatus == .fromAToB {
                                    Text("Stop A→B Simulation")
                                } else {
                                    Text("A→B Linear Simulation")
                                }
                            }
                        }
                        .disabled(locationController.simulationStatus == .stopping)
```

(Verify the exact existing function signatures and labels with the `sed` command in Step 1 — if any string literal differs, preserve the existing one.)

- [ ] **Step 4: Build**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Manual regression — spec §11 scenarios 3, 4, 10**

1. Run app, simulate a route on whatever device is available (or Simulator).
2. **(Scenario 3)** Click Stop, then immediately click Stop again → button shows greyed `Stopping…`, second click is no-op.
3. **(Scenario 4)** Wait for Stop to complete (~1 s), then click Simulate Route again → restarts cleanly without password.
4. **(Scenario 10)** Drag the speed slider mid-route, then click Stop → no orphan re-generation task, simulation ends cleanly.

- [ ] **Step 6: Commit**

```bash
git add SimVirtualLocation/Views/LocationSettingsPanel.swift
git commit -m "feat(ui): Stop button shows Stopping… spinner during teardown

Button is .disabled in .stopping state so repeated clicks are no-ops."
```

---

## Task 16: Remove RSD UI fields from LocationSettingsPanel

**Files:**
- Modify: `SimVirtualLocation/Views/LocationSettingsPanel.swift`

- [ ] **Step 1: Locate iOS 17+ UI elements**

```bash
grep -n 'RSD\|useRSD\|iOS 17' SimVirtualLocation/Views/LocationSettingsPanel.swift
```

There should be: one Toggle for `useRSD` and two TextFields bound to `RSDAddress` / `RSDPort`.

- [ ] **Step 2: Delete each block**

For each grep hit:
- Delete the `Toggle("iOS 17+", ...)` line and the surrounding `if` wrapper that gated the next two fields.
- Delete the `TextField` lines bound to `$locationController.RSDAddress` and `$locationController.RSDPort`.
- Keep the rest of the panel intact.

If any TextField is wrapped inside a conditional `if locationController.useRSD { ... }`, replace the entire conditional block with nothing — the conditional itself becomes dead because useRSD is determined internally by device version.

- [ ] **Step 3: Build**

Expected: `** BUILD SUCCEEDED **`.

If the build still complains about `RSDAddress`/`RSDPort` in another View file, repeat the same procedure there.

- [ ] **Step 4: Commit**

```bash
git add SimVirtualLocation/Views/LocationSettingsPanel.swift
git commit -m "ui: remove RSD Address/Port inputs and iOS 17+ toggle

useRSD is now derived internally from device.version. The tunneld
daemon resolves the address/port so the user never sees them."
```

---

## Task 17: Slim down Runner.swift

After Tasks 9 and 11, all iOS pymobiledevice3 code paths go through `MobileDeviceClient`. Runner only needs the Android adb wrappers and the Simulator notification helper.

**Files:**
- Modify: `SimVirtualLocation/Logic/Runner.swift`

- [ ] **Step 1: Delete iOS-related methods**

Open `Runner.swift`. Delete the entire bodies of:
- `checkDeveloperModeStatus(udid:)`
- `revealDeveloperMode(udid:)`
- `runOnIos(location:udid:showAlert:)`
- `runOnNewIos(location:udid:RSDAddress:RSDPort:showAlert:)`
- `playGPXLegacy(udid:gpxURL:showAlert:)`
- `playGPXRSD(udid:gpxURL:RSDAddress:RSDPort:showAlert:)`
- `resetIos(udid:useRSD:RSDAddress:RSDPort:showAlert:)`
- `runLocationTask(_:label:showAlert:)`
- `runLongRunningTask(_:label:showAlert:)`
- `taskForIOS(args:)`
- `DeveloperModeStatus` enum
- `shouldSuppressError(_:)`
- `waitExit(_:)`
- `stopCurrentTask()` — the Android-only path doesn't need it; remove and audit callers.

Audit callers of `stopCurrentTask`:

```bash
grep -n 'runner.stopCurrentTask\|stopCurrentTask' SimVirtualLocation/
```

If `LocationController` still calls `runner.stopCurrentTask()` anywhere, remove that line (the per-tick `setLocation` calls are short-lived, and `MobileDeviceClient` manages its own long-running handles).

- [ ] **Step 2: Keep what Runner still needs**

After deletion, `Runner.swift` should contain only:
- `var timeDelay`
- `runOnSimulator(...)`
- `runOnAndroid(...)`
- `resetAndroid(...)`
- `getFullPathOf(_:)` (still used by Android adb path setup)
- A `taskForAndroid` private helper.

Confirm with:

```bash
wc -l SimVirtualLocation/Logic/Runner.swift
```

Expected: roughly 100–150 lines.

- [ ] **Step 3: Build**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add SimVirtualLocation/Logic/Runner.swift SimVirtualLocation/Logic/LocationController.swift
git commit -m "refactor: drop iOS code from Runner, leaving Android + Simulator only"
```

---

## Task 18: README updates

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite the iOS 17+ section**

In `README.md`, locate the current iOS 17+ block (around lines 50–58, starting with `**For iOS 17+ devices:**`).

Replace those lines with:

```markdown
**For iOS 17+ devices:**

No manual configuration required.

1. Connect the device and select it from the dropdown.
2. Click **Connect Device**. The first time after a Mac reboot, macOS asks for your admin password. This starts `pymobiledevice3 remote tunneld` as a background root process. The daemon auto-discovers iOS 17+ devices and provides tunnel info to subsequent commands.
3. Click **Start**. All subsequent Start/Stop operations require no password.
4. The daemon stays alive across app launches. It is reset only on Mac reboot or if you kill it from Activity Monitor.
```

- [ ] **Step 2: Add a Features bullet**

Locate the `## Features` section near the top of the README. Add this bullet at the end of the list (preserve existing punctuation style):

```markdown
- **One-time authorization for iOS 17+.** A background `tunneld` daemon is launched on first connect; subsequent Start/Stop operations require no password. Survives app restart; is reset only by Mac reboot.
```

- [ ] **Step 3: Add a Troubleshooting section**

Add this new section near the end of the README (before any "License" or footer):

```markdown
## Troubleshooting

### Why is the password prompt back?

Expected when:
- The Mac was rebooted (the `tunneld` daemon does not persist across reboots).
- You killed `pymobiledevice3` from Activity Monitor.

To force a re-prompt manually:

```shell
sudo pkill -f 'pymobiledevice3 remote tunneld'
```

Next time you click **Connect Device** on an iOS 17+ device, the prompt returns.

### Tunneld status check

```shell
ps aux | grep '[r]emote tunneld'
curl -s http://127.0.0.1:49151/ | head
```

If the `curl` output is empty or "Connection refused", the daemon is not running.

### Connect Device hangs at "Launching tunnel…"

Most likely the daemon started but cannot reach the device. Verify:

1. `pymobiledevice3 usbmux list` lists the device.
2. The device is unlocked.
3. Developer Mode is enabled on the device.
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(readme): document tunneld-based iOS 17+ flow + Troubleshooting"
```

---

## Task 19: Final regression sweep

This is the verification gate. No code changes; we walk through every scenario from spec §11 against a clean build.

- [ ] **Step 1: Build a fresh Debug binary**

```bash
xcodebuild clean -project SimVirtualLocation.xcodeproj -scheme SimVirtualLocation
xcodebuild -project SimVirtualLocation.xcodeproj -scheme SimVirtualLocation -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Reboot the Mac**

(Needed to start scenarios 1 / 5 / 6 from a known-clean tunneld state.)

After reboot, verify no tunneld is running:

```bash
ps aux | grep '[r]emote tunneld'
```

Expected: no output.

- [ ] **Step 3: Walk through the regression matrix**

For each row from spec §11, perform the action and record PASS/FAIL/N/A in a temp file `regression-2026-05-14.md`:

| # | Scenario | Expected | Result |
|---|----------|----------|--------|
| 1 | Fresh Mac reboot → open App → select iOS 17+ → Connect | One password prompt, then `.connected` | ☐ |
| 2 | After (1) → Start route | No prompt; puck moves; GPX written | ☐ |
| 3 | During route → click Stop twice quickly | Button greys `Stopping…`; second click no-op | ☐ |
| 4 | After Stop completes → Start again | No prompt; route replays | ☐ |
| 5 | Quit App → reopen → Connect same iOS 17+ device | No prompt | ☐ |
| 6 | `sudo pkill -f 'pymobiledevice3 remote tunneld'` → Connect | Prompt returns once; connects | ☐ |
| 7 | Select iOS 16- device → Connect | No prompt; mount path used | ☐ |
| 8 | Select Simulator → Start | No prompt; simctl path used | ☐ |
| 9 | Mid-simulation: unplug cable | Alert + full state reset | ☐ |
| 10 | Drag speed slider mid-route then click Stop | Cleanup; no orphan task | ☐ |

For each FAIL, file an issue or fix inline; do not mark the plan complete.

- [ ] **Step 4: Final summary commit**

```bash
git add regression-2026-05-14.md
git commit -m "docs: record regression sweep outcomes for tunneld refactor"
```

(If the regression file is per-engineer scratch, leave it untracked and skip this step.)

- [ ] **Step 5: Verify final file sizes**

```bash
wc -l SimVirtualLocation/Logic/*.swift
```

Expected approximate sizes (per design spec §9):
- `LocationController.swift`: ~900 (was 1392)
- `Runner.swift`: ~120 (was 491)
- `MobileDeviceClient.swift`: ~400 (new)
- `AppError.swift`: ~120 (new)
- `ErrorHandler.swift`: ~50 (new)

If any file is dramatically off these estimates, audit for stale code that should have been removed in earlier tasks.

---

## Self-Review

(Performed during plan authoring; recording here for traceability.)

**Spec coverage:**
- §2 goal "one password prompt" → Tasks 10, 11.
- §2 goal "eliminate log-file monitoring" → Task 12.
- §2 goal "typed-error pipeline" → Tasks 1, 2, 3, 4.
- §2 goal "Stopping… disabled state" → Tasks 13, 14, 15.
- §2 goal "thinner LocationController + Runner" → Tasks 12, 17.
- §5 API for MobileDeviceClient → Tasks 5, 6, 7, 8, 10.
- §6 AppError + ErrorHandler → Tasks 1, 2.
- §7 Stopping UX → Tasks 13, 14, 15.
- §8 removals → Tasks 12, 16, 17.
- §10 README → Task 18.
- §11 regression matrix → Task 19.
- §12 implementation slicing → tasks aligned with the six slices.

**Placeholder scan:** no "TBD" / "implement later" / "add error handling" patterns. Every code step has executable Swift. All commands are exact.

**Type consistency:**
- `MobileDeviceClient.Transport` used consistently in tasks 8, 9, 11, 14.
- `ProcessRunner.LongRunningHandle` used in tasks 5, 8, 11.
- `TunneldStatus` defined in task 5, populated in task 10.
- `GPXPlayback.Endpoint.rsd` signature change (lost `address:port`) handled in task 11 with explicit call-site update.
- `SimulationStatus.stopping` added in task 13, used in tasks 14, 15; `isMockingActive` semantics aligned with task 14's idempotent guard.
