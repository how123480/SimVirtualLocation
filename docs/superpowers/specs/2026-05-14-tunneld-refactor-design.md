# Design — tunneld-based daemon + Refactor + Stopping UX

**Status:** Draft for approval
**Owner:** howardtseng
**Created:** 2026-05-14

## 1. Background & Motivation

The current architecture for iOS 17+ devices has three pain points:

1. **Every Start and Stop prompts for the admin password.** `pymobiledevice3 remote start-tunnel` requires root, so the app uses `NSAppleScript ... with administrator privileges` to launch it. `stopRSDTunnel` also calls `pkill ... with administrator privileges`, prompting again.
2. **A log file must be tail-monitored** to extract `RSD Address` and `RSD Port` from `start-tunnel`'s stdout. This is fragile and adds the `monitorRSDLog` timer / `parseRSDOutput` regex code path.
3. **Error handling is duplicated** across `Runner.runLocationTask`, `Runner.runLongRunningTask`, `LocationController.showAlert`, and various sites that inline `if text.contains(...)` matching. There is no single place to translate stderr into a typed error and decide whether to reset app state.

Additionally, the Stop button has no in-flight visual state; users can spam-click it during the async teardown.

## 2. Goals

- One password prompt per Mac boot for iOS 17+ users (zero for iOS 16 / Simulator / Android users).
- Eliminate log-file monitoring and manual `--rsd <addr> <port>` plumbing.
- Single typed-error pipeline (`AppError` + `ErrorHandler`).
- Stop button shows a "Stopping..." disabled state during async teardown; cannot be re-clicked.
- LocationController + Runner significantly thinner; pymobiledevice3 access goes through a single abstraction.

## 3. Non-Goals

- No code signing / Developer ID / SMAppService / LaunchDaemon plist installation. (Considered but rejected — adds installer complexity, requires Apple Developer membership.)
- No persistence of tunneld across Mac reboots. One password per boot is acceptable.
- No SwiftUI rewrite or further view-layer refactor beyond the Stop button and removal of the RSD input fields.
- No new unit-test framework. Verification stays manual against the regression matrix in §11.
- iOS 16 path stays exactly as today — tunneld is iOS-17+ only.

## 4. High-Level Architecture

```
SimVirtualLocation/Logic/
├── AppError.swift             [new] enum AppError + classification helpers
├── ErrorHandler.swift         [new] @MainActor handle(_:context:) — single funnel
├── MobileDeviceClient.swift   [new] all pymobiledevice3 access; owns TunneldSupervisor
├── Runner.swift               [thin] Android adb + Simulator simctl + path search only
├── LocationController.swift   [thinner] delegates to MobileDeviceClient + ErrorHandler
├── GPXGenerator.swift         [unchanged]
└── Logger.swift               [unchanged]
```

### Flow on user actions

```
App launch                       — no password, no tunneld
User selects device              — version detected; iOS 17+ ⇒ transport = .rsd
User clicks "Connect Device"
  iOS 16-                        — mountDeveloperImage; never touches tunneld; no password
  iOS 17+                        — MobileDeviceClient.ensureTunneldRunning()
                                   ├─ pgrep / lsof :49151 hits  ⇒ poll http://127.0.0.1:49151 until 200; .ready
                                   └─ not running                ⇒ osascript admin → launch as root → poll → .ready
                                                                   (this is the only password prompt)
                                   (iOS 17+ does NOT call mountDeveloperImage — tunneld
                                    handles the equivalent setup transparently, matching
                                    today's behaviour.)
User clicks Start / Stop         — no password; commands use `--udid` only,
                                   tunneld auto-resolves the tunnel

The `useRSD` field is removed from the UI but retained as a private
LocationController boolean, derived from `device.version >= 17` at device
selection time. It is the sole source for `currentTransport()` (returns
`.rsd(udid:)` when true, `.legacy(udid:)` otherwise).
```

## 5. MobileDeviceClient — Public API

```swift
@MainActor
final class MobileDeviceClient {
    @Published private(set) var tunneldStatus: TunneldStatus

    enum TunneldStatus {
        case idle
        case authorizing
        case launching
        case ready
        case failed(AppError)
    }

    enum Transport: Equatable {
        case legacy(udid: String)   // iOS 16-
        case rsd(udid: String)      // iOS 17+, address/port resolved by tunneld
    }

    enum MountResult { case mounted, alreadyMounted }

    // Tunneld lifecycle
    func ensureTunneldRunning() async throws   // only call site that may prompt password
    func killTunneld() async throws            // admin; manual-only

    // Device commands
    func listDevices() async throws -> [Device]
    func checkDeveloperMode(udid: String) async throws -> Bool
    func revealDeveloperMode(udid: String) async throws
    func mountDeveloperImage(udid: String) async throws -> MountResult
    func setLocation(_ coord: CLLocationCoordinate2D, transport: Transport) async throws
    func clearLocation(transport: Transport) async throws
    func playGPX(_ url: URL, transport: Transport) async throws -> GPXPlaybackHandle

    final class GPXPlaybackHandle {
        var isPlaying: Bool { get }
        func stop() async   // SIGTERM, awaits termination
    }
}
```

### Internal collaborators (not exposed)

- `ProcessRunner` — wraps `Process`; methods `run(_:) -> ProcessResult` (one-shot) and `runDiscardingOutput(_:) -> LongRunningHandle` (GPX play). Same `taskForIOS` path-search currently in `Runner.swift`.
- `TunneldSupervisor` — `isRunning() async`, `waitForReady(timeout:) async throws`, `launchAsRoot() async throws`, `kill() async throws`.

### Command shape change (iOS 17+)

```
old: pymobiledevice3 developer dvt simulate-location set --rsd <addr> <port> -- <lat> <lng>
new: pymobiledevice3 developer dvt simulate-location set --udid <UDID>          -- <lat> <lng>

old: pymobiledevice3 developer dvt simulate-location play --rsd <addr> <port> <gpx>
new: pymobiledevice3 developer dvt simulate-location play --udid <UDID>          <gpx>

old: pymobiledevice3 developer dvt simulate-location clear --rsd <addr> <port>
new: pymobiledevice3 developer dvt simulate-location clear --udid <UDID>
```

tunneld auto-discovery means `--rsd` is no longer needed.

### Tunneld readiness check

- Liveness: `pgrep -f 'pymobiledevice3 remote tunneld'` (or `lsof -nP -iTCP:49151 -sTCP:LISTEN`).
- Readiness: `URLSession` GET to `http://127.0.0.1:49151/`. Poll every 500 ms up to 30 s; success on any 2xx.

## 6. AppError + ErrorHandler

```swift
enum AppError: Error {
    // Tooling
    case pymobiledevice3NotInstalled
    case adbNotConfigured

    // Tunneld
    case tunneldAuthorizationCancelled
    case tunneldAuthorizationFailed(String)
    case tunneldFailedToStart(String)
    case tunneldNotReady

    // Device
    case deviceNotSelected
    case deviceLocked
    case developerModeDisabled
    case noBootedSimulators
    case noRouteToHost
    case mountFailed(String)
    case alreadyMounted

    // Command execution
    case processFailed(command: String, stderr: String)
    case invalidCoordinate

    // Suppressed
    case harmlessWarning(String)
}

extension AppError {
    var userMessage: String { ... }
    var requiresStateReset: Bool { /* only noRouteToHost today */ }
    var shouldShowAlert: Bool   { /* false for harmlessWarning and tunneldAuthorizationCancelled */ }
    static func from(stderr: Data, context: Context) -> AppError
    enum Context { case setLocation, playGPX, mount, listDevices, tunneldStart }
}
```

```swift
@MainActor
final class ErrorHandler {
    private weak var controller: LocationController?

    func handle(_ error: Error, context: String = #function) {
        let appError = (error as? AppError) ?? .processFailed(
            command: context, stderr: error.localizedDescription)
        AppLogger.shared.error("[\(context)] \(appError)")
        if appError.requiresStateReset { controller?.resetAllState() }
        if appError.shouldShowAlert    { controller?.presentAlert(message: appError.userMessage) }
    }
}
```

Call sites in `LocationController` become:

```swift
do {
    try await client.setLocation(coord, transport: currentTransport())
} catch {
    errorHandler.handle(error)
}
```

`LocationController.showAlert(_:)`'s embedded `if text.contains("No route to host")` block moves into `ErrorHandler` + `resetAllState()`.

## 7. Stopping UX

Add a new case to `SimulationStatus`:

```swift
enum SimulationStatus {
    case idle, route, fromAToB, mocking, stopping
}

extension SimulationStatus {
    var displayText: String { /* "Stopping..." for .stopping */ }
    var isMockingActive: Bool { /* .stopping is NOT mocking-active */ }
}
```

`LocationController.stopSimulation` becomes `async` and idempotent:

```swift
func stopSimulation(clearAnnotations: Bool = true) async {
    guard simulationStatus.isMockingActive else { return }   // idempotent guard
    simulationStatus = .stopping
    pendingSpeedRegenTask?.cancel(); pendingSpeedRegenTask = nil
    timer?.invalidate(); timer = nil
    await gpxPlaybackHandle?.stop(); gpxPlaybackHandle = nil
    do {
        try await client.clearLocation(transport: currentTransport())
    } catch {
        errorHandler.handle(error)
    }
    mapView.mkMapView.removeOverlays(mapView.mkMapView.overlays)
    route = nil; tracks = []; currentPolyline = []
    if clearAnnotations {
        mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
        annotations = []
    }
    simulationStatus = .idle
}
```

`LocationSettingsPanel`'s two Stop buttons become:

```swift
Button {
    Task { await locationController.stopSimulation() }
} label: {
    HStack {
        if locationController.simulationStatus == .stopping {
            ProgressView().controlSize(.small)
            Text("Stopping...")
        } else {
            Text(/* existing dynamic label */)
        }
    }
}
.disabled(locationController.simulationStatus == .stopping)
```

The idempotent guard in `stopSimulation` ensures a second click during teardown is a no-op even if SwiftUI re-enables the button between frames.

## 8. Removals

From `LocationController.swift`:
- `startRSDTunnel`, `stopRSDTunnel`, `monitorRSDLog`, `parseRSDOutput`, `killRSDTunnel`
- `@Published var RSDAddress`, `@Published var RSDPort`
- `mountDeveloperImage` body (moves to `MobileDeviceClient`)
- `getConnectedDevices` (moves to `MobileDeviceClient`)
- The `if text.contains("No route to host")` block inside `showAlert` (moves to `ErrorHandler` + new `resetAllState()`)

From `Runner.swift`:
- All iOS-related methods (`runOnIos`, `runOnNewIos`, `playGPXLegacy`, `playGPXRSD`, `resetIos`, `checkDeveloperModeStatus`, `revealDeveloperMode`, `taskForIOS`) — moved to `MobileDeviceClient`.
- `runLocationTask`, `runLongRunningTask`, `shouldSuppressError`, `waitExit` — moved to `MobileDeviceClient`'s internal `ProcessRunner`.
- `stopCurrentTask` — split: per-command Process management moves to `MobileDeviceClient`; `Runner` retains its own for Android.

From `LocationSettingsPanel.swift`:
- "iOS 17+" checkbox, "RSD Address" TextField, "RSD Port" TextField. iOS 17+ vs legacy is internally inferred from `device.version >= 17`.

## 9. Estimated Size Impact

- `LocationController.swift`: 1392 → ~900 lines.
- `Runner.swift`: 491 → ~120 lines.
- `MobileDeviceClient.swift`: new, ~400 lines.
- `AppError.swift` + `ErrorHandler.swift`: new, ~150 lines combined.

## 10. README Changes

### iOS 17+ section (replaces current ~lines 50–58)

```
**For iOS 17+ devices:**
No manual configuration required.
1. Connect device and select from the dropdown.
2. Click "Connect Device". The first time after a Mac reboot, macOS will ask
   for your admin password (this starts `pymobiledevice3 remote tunneld` as a
   background root process; it auto-discovers iOS 17+ devices and serves tunnel
   info to subsequent commands).
3. Click Start. All subsequent Start/Stop operations require no password.
4. The daemon stays alive across app launches. It is killed only on Mac reboot
   or via Activity Monitor.
```

### Features bullet (add)

```
- **One-time authorization for iOS 17+.** A background tunneld daemon is launched
  on first connect; subsequent Start/Stop operations require no password.
  Survives app restart; is reset only by Mac reboot.
```

### New "Troubleshooting" section

```
## Troubleshooting

### Why is the password prompt back?
Expected when:
- The Mac was rebooted (the tunneld daemon does not persist across reboots).
- You killed pymobiledevice3 from Activity Monitor.

To force re-auth manually:
    sudo pkill -f 'pymobiledevice3 remote tunneld'
Next time you click "Connect Device" on an iOS 17+ device the prompt returns.

### Tunneld status check
    ps aux | grep '[r]emote tunneld'
    curl -s http://127.0.0.1:49151/ | head

### Connect Device hangs at "Launching tunnel..."
Most likely tunneld started but cannot reach the device. Verify:
1. `pymobiledevice3 usbmux list` lists the device.
2. The device is unlocked.
3. Developer Mode is enabled on the device.
```

## 11. Regression Matrix

| # | Scenario | Expected |
|---|----------|----------|
| 1 | Fresh Mac reboot → open App → select iOS 17+ → Connect | One password prompt, then `.connected` |
| 2 | After (1) → Start route | No prompt; puck moves; GPX written |
| 3 | During route → click Stop → click Stop again immediately | Button greys with "Stopping..."; second click is no-op |
| 4 | After Stop completes → Start again | No prompt; route replays |
| 5 | Quit App → reopen → Connect same iOS 17+ device | No prompt (tunneld still alive) |
| 6 | Activity Monitor kill of tunneld → Connect | Prompt returns once; connects |
| 7 | Select iOS 16 device → Connect | No prompt; never touches tunneld |
| 8 | Select Simulator → Start | No prompt |
| 9 | Mid-simulation: unplug cable to trigger `No route to host` | Alert appears; all state reset (annotations/overlays/timer cleared) |
| 10 | Drag speed slider mid-route then click Stop | `pendingSpeedRegenTask` cancelled cleanly; stop completes |

## 12. Implementation Slicing (for writing-plans handoff)

1. Introduce `AppError` + `ErrorHandler` only; route existing `showAlert` calls through it. Behaviour unchanged.
2. Build `MobileDeviceClient` skeleton; migrate iOS-16 path off `Runner`. Run regressions 1, 7, 8.
3. Add `TunneldSupervisor`; switch iOS-17+ to tunneld + `--udid` (no `--rsd`). Run regressions 1–6.
4. Add `SimulationStatus.stopping`; make `stopSimulation` async + idempotent; wire up button state. Run regressions 3, 4, 10.
5. Delete RSD UI fields and `LocationController` RSD code. Run regressions 1–8.
6. README rewrite (iOS 17+ section, Features bullet, Troubleshooting).
