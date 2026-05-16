# AGENTS.md - SimVirtualLocation Project Guide

This document provides comprehensive guidance for AI coding agents working on the SimVirtualLocation macOS application.

## Project Overview

SimVirtualLocation is a macOS 11+ application for mocking iOS device and simulator locations in real-time. Built with SwiftUI, it supports both iOS simulators/devices and Android devices/emulators.

**Tech Stack:**
- Language: Swift 5+
- UI Framework: SwiftUI
- Target: macOS 11.0+
- Build System: Xcode
- External Tools: pymobiledevice3 (Python), adb (Android), xcrun simctl (iOS Simulator)

---

## Build Commands

### Build the Application
```bash
xcodebuild -project SimVirtualLocation.xcodeproj \
  -scheme SimVirtualLocation \
  -configuration Debug \
  -destination 'platform=macOS' \
  build \
  CODE_SIGNING_ALLOWED=NO
```

### Build for Release
```bash
xcodebuild -project SimVirtualLocation.xcodeproj \
  -scheme SimVirtualLocation \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

### Build and Run (macOS)
```bash
xcodebuild -project SimVirtualLocation.xcodeproj \
  -scheme SimVirtualLocation \
  -configuration Debug \
  -destination 'platform=macOS' \
  build \
  CODE_SIGNING_ALLOWED=NO && \
open "$(ls -td ~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/SimVirtualLocation.app | head -1)"
```

### Clean Build
```bash
xcodebuild clean -project SimVirtualLocation.xcodeproj -scheme SimVirtualLocation
```

### List Available Schemes/Targets
```bash
xcodebuild -list -project SimVirtualLocation.xcodeproj
```

---

## Testing

**Note:** This project currently has no test suite. Tests are disabled but `ENABLE_TESTABILITY = YES` is set in the project configuration.

### If Tests Are Added in Future:
```bash
# Run all tests
xcodebuild test -project SimVirtualLocation.xcodeproj \
  -scheme SimVirtualLocation \
  -destination 'platform=macOS'

# Run a single test class
xcodebuild test -project SimVirtualLocation.xcodeproj \
  -scheme SimVirtualLocation \
  -destination 'platform=macOS' \
  -only-testing:SimVirtualLocationTests/TestClassName

# Run a single test method
xcodebuild test -project SimVirtualLocation.xcodeproj \
  -scheme SimVirtualLocation \
  -destination 'platform=macOS' \
  -only-testing:SimVirtualLocationTests/TestClassName/testMethodName
```

---

## Code Style Guidelines

### File Structure
- Each file starts with a header comment including filename and creation date
- Files are organized by type: Views/, Logic/, Models/
- Structure: Header → Imports → Main Type → Extensions

### Imports
- Use explicit imports: `import SwiftUI`, `import CoreLocation`, `import MapKit`
- Order: Foundation first, then Apple frameworks, then third-party (if any)
- Remove unused imports

### Formatting
- **Indentation:** 4 spaces (no tabs)
- **Line Length:** No strict limit, but keep it reasonable (~120 chars preferred)
- **Braces:** Opening brace on same line, closing brace on new line
- **Spacing:** 
  - One space after keywords (`if`, `guard`, `func`)
  - No space between function name and parentheses
  - One blank line between methods

### Naming Conventions
- **Classes/Structs/Enums:** PascalCase (`LocationController`, `DeviceMode`)
- **Functions/Variables:** camelCase (`setCurrentLocation`, `bootedSimulators`)
- **Constants:** camelCase with descriptive names (`maxTasksCount`, `iOSDeveloperImagePath`)
- **Private Properties:** camelCase with `private` modifier (`private var isMapCentered`)
- **Enums:** PascalCase with lowercase cases (`enum DeviceMode { case simulator, device }`)

### Type Annotations
- Use explicit types for public properties: `var speed: Double = 60.0`
- Type inference is acceptable for obvious local variables
- Always specify return types for public methods
- Use `CLLocationCoordinate2D`, `MKMapPoint`, etc. explicitly

### Property Organization (MARK Comments)
Use `// MARK:` comments to organize code sections in this order:
1. `// MARK: - Enums` (nested types first)
2. `// MARK: - Public` or `// MARK: - Public Properties`
3. `// MARK: - Publishers` (for `@Published` properties)
4. `// MARK: - Private` or `// MARK: - Private Properties`
5. `// MARK: - Init`
6. `// MARK: - Public` or `// MARK: - Public Methods`
7. `// MARK: - Protocol Conformance` (e.g., `// MARK: - MKMapViewDelegate`)
8. `// MARK: - Private` or `// MARK: - Private Methods`

### SwiftUI Patterns
- Use `@Published` for observable properties in `ObservableObject` classes
- Use `@ObservedObject`, `@StateObject`, or `@EnvironmentObject` appropriately
- Prefer `@EnvironmentObject` for passing controllers to child views
- Keep view bodies readable; extract complex views into separate structs
- Use view modifiers for reusable UI patterns
- **All UI chrome — buttons, dividers, section labels, status indicators, containers — must come from `Views/DesignSystem.swift`.** See "UI Design System" below. Do not call `.bordered`, `.borderedProminent`, or build one-off `RoundedRectangle`/`Color.gray` chrome in feature code.

### Concurrency
- **Controllers are isolated to `@MainActor`.** UI state (`@Published` properties) and view-bound work happens on the main actor by default; only delegate methods that the system invokes off-main are explicitly marked `nonisolated` (currently the `CLLocationManagerDelegate` callbacks). Those nonisolated methods hop back via `Task { @MainActor in ... }`.
- Use `async/await` for any external command. The `Runner` class wraps every `Process` with `await waitExit(_:)` so callers never block the main actor.
- **Do not use `DispatchQueue.main.async`.** Replace with `Task { @MainActor in ... }` (when called from a non-MainActor context) or just call the method directly when already on `@MainActor`. The codebase no longer contains any `DispatchQueue` usage in the main app target.
- Background work that must escape the main actor (e.g., the `NSAppleScript` sudo prompt for the RSD tunnel) uses `Task.detached(priority: .userInitiated)` and explicitly hops back via `await MainActor.run { ... }` to mutate UI state.
- `Timer.scheduledTimer` callbacks run on the current run loop; when they touch `@MainActor` state we wrap the body in `Task { @MainActor in ... }`.

### Error Handling
- Use `try/catch` for operations that can fail.
- Show user-friendly alerts via `showAlert(_ text: String)` on `LocationController`.
- **Never use `print(...)` in production code.** All diagnostics go through `AppLogger.shared` so they are sanitized, persisted, and rotated.
- Custom errors should conform to `Error` and `CustomStringConvertible`.

### Optional Handling
- Use `guard let` for early returns.
- Use `if let` for conditional unwrapping when needed.
- Avoid force unwrapping (`!`) unless absolutely certain value exists.

### Closures
- Use trailing closure syntax when it's the last parameter.
- Use `[weak self]` capture lists to prevent retain cycles, especially in `Timer` callbacks and asynchronous `MKLocalSearch` continuations.

### Comments
- All inline comments are written in **English**.
- Use `// MARK:` to organize code sections.

---

## Architecture Patterns

### App Structure
- **Main.swift:** App entry point with `@main` and SwiftUI `App` protocol
- **Controllers:** Business logic classes (e.g., `LocationController`, all annotated `@MainActor`) conforming to `ObservableObject`
- **Views:** SwiftUI views organized by feature (iOS/, Android/, Map, etc.)
- **Models:** Data structures (`Device`, `Simulator`, `Track`, `Location`, `LogEntry`, `DeviceStatus`, `SimulationStatus`)
- **Logic:** Utility classes (`Runner`, `NotificationSender`, `AppLogger`)

### Key Components
- **LocationController:** Main `@MainActor` business logic coordinator, owns `MapView`, `Runner`, and `GPXPlayback`. Maintains `deviceStatus: DeviceStatus` (replaces the legacy `Bool isDeviceActive` + `String tunnelStatus`) and `simulationStatus: SimulationStatus` (replaces `Bool isSimulating` + `simulationType`). Computed property `isDeviceReady` ensures location updates only fire when the iOS tunnel is connected. Computed property `isRouteSimulationActive` is used to lock A/B annotations during route simulation.
- **Runner:** Handles execution of external commands (pymobiledevice3, adb, xcrun) using `async/await`. Provides both per-point `set` calls (`runOnIos` / `runOnNewIos`) and long-running `play` calls (`playGPXLegacy` / `playGPXRSD`). No `DispatchQueue` left.
- **GPXGenerator (Logic/GPXGenerator.swift):** Pure data tool. Takes a polyline + speed (km/h), uniformly samples points 1 second apart in time (`stepDistance = speed_mps * sampleInterval`), serialises to GPX 1.1 XML and writes to `~/Library/Application Support/SimVirtualLocation/routes/<name>.gpx`. Auto-prunes when more than 50 files accumulate.
- **GPXPlayback (Logic/GPXGenerator.swift):** `@MainActor` lifecycle wrapper around `pymobiledevice3 ... simulate-location play`. Tracks the currently playing GPX URL and endpoint (`legacy(udid)` / `rsd(udid, address, port)`). `start(...)` cancels any previous task before launching the new one; `stop()` terminates and clears state.
- **AppLogger:** Singleton logger (see "Logging" below).
- **MapView:** Wraps `MKMapView` in SwiftUI using `NSViewRepresentable`.
- **ContentView:** Root view assembling all UI components. Serves as the centralized manager for global keyboard shortcuts (`Esc` to unfocus, `d` for debug mode, arrow keys for joystick), utilizing `@FocusState` to prevent conflicts with text input fields.

### Route / A→B simulation on iOS device (GPX path)

When the user starts **Simulate Route** or **A→B Linear Simulation** with `deviceType == 0 && deviceMode == .device && deviceStatus.isReady`, the controller switches to the GPX path:

1. `simulateRoute()` / `simulateFromAToB()` build `tracks` (linear segments, used for the on-screen orange puck) **and** `currentPolyline: [CLLocationCoordinate2D]` — the full poly used for GPX generation.
2. `kickoffGPXPlaybackIfNeeded()` calls `GPXGenerator.render(polyline:speedKmh:name:)` to write a new file (e.g. `route-1717327200-3f9a2d.gpx`), then calls `GPXPlayback.start(gpxURL:endpoint:alert:)`. `pymobiledevice3` walks through the file at 1 trkpt/second.
3. The local 0.1 s timer (`startMovementTimer` → `performMovement`) keeps moving the visual puck. Crucially, when `gpxPlayback.isPlaying == true`, `performMovement` skips `run(location:)` so we never double-drive the device.
4. **Dynamic speed change without restart from A.** `@Published var speed` has a `didSet` that calls `handleSpeedChange(oldValue:)`. After a 0.4 s debounce (so dragging the slider doesn't thrash), it calls `remainingPolyline()` (= current track's puck position → end of route) and feeds it back to `startGPXPlayback(...)`. The new GPX is written, the previous `pymobiledevice3 play` is SIGTERMed, and a new one starts at the user's *current* visual position. The map puck does not jump.
5. **A/B lock during simulation.** `isRouteSimulationActive` (= `simulationStatus == .route || .fromAToB`) gates `addLocation`, `setSelectedLocation`, `setToCoordinate`, `handlePointsModeChange`, and the joystick (`handleKeyEvent`). All of those silently no-op so map clicks, search, "Apply to A", or arrow keys can't reset the route mid-flight. Only `stopSimulation()` clears the lock.
6. **Update interval picker** (`timeScale`) is hidden in `LocationSettingsPanel` when iOS device GPX path is active because the cadence is intrinsic to the GPX file.

For iOS Simulator and Android, Route / A→B keep the original per-tick approach (`Runner.runOnSimulator` via `DistributedNotificationCenter` / `Runner.runOnAndroid` via `adb am broadcast`), since neither has a GPX equivalent.

### Status Enums (`Models/DeviceStatus.swift`)
- `DeviceStatus`: `.idle`, `.checkingDeveloperMode`, `.waitingAuthorization`, `.mounting`, `.connecting`, `.connected`, `.error(String)`. Use `deviceStatus.displayText` whenever a UI button needs to show progress; use `deviceStatus.isReady` to gate hardware updates.
- `SimulationStatus`: `.idle`, `.route`, `.fromAToB`, `.mocking`, `.stopping`. The joystick uses `simulationStatus.isMockingActive` to decide whether arrow keys should send live updates to the hardware. `.stopping` is the async-teardown bookkeeping state — UI buttons should show a spinner and disable input while a stop is in flight, then snap back to `.idle` on completion.
- When you add a new status, also add the localized `displayText` so UI never has to format strings inline.

---

## UI Design System (`Views/DesignSystem.swift`)

The entire control panel uses one shared visual language. The single file `Views/DesignSystem.swift` owns all tokens and components.

### Tokens — `enum PanelTheme`

All fills are expressed as `Color.primary.opacity(...)` so they automatically invert for dark mode. **Never** hardcode `Color.gray`, `Color.white`, `NSColor.windowBackgroundColor`, etc. for control-panel surfaces.

| Token | Value | Use |
|---|---|---|
| `containerFill` | `Color.primary.opacity(0.045)` | Group container backgrounds (Saved Locations) |
| `rowFill` | `Color.primary.opacity(0.035)` | Per-row backgrounds inside lists |
| `buttonFill` / `Hover` / `Pressed` | `0.11 / 0.16 / 0.22` | Standard `PanelButton` states |
| `separator` / `separatorStrong` | `NSColor.separatorColor` @ 0.4 / 0.6 | Hairlines |
| `radius` | `6` | All buttons |
| `radiusContainer` | `10` | All grouped containers |
| `textPrimary` / `textSecondary` / `textTertiary` | semantic | Three text levels; no others |

### Components

- **`PanelButton(title:icon:style:isLoading:disabled:action:)`** — the only button used in feature code. Text always centered via `frame(maxWidth: .infinity)`. Built-in hover and pressed transitions, optional inline `ProgressView`, optional `disabled` opacity. Four styles:
  - `.standard` — subtle neutral fill, primary-color text. Most controls.
  - `.prominent` — accent-tinted (light blue wash + accent text + accent border), **not** solid blue. Reserved for the primary CTA in a section (Start, Apply to A, Simulate Route).
  - `.destructive` — red-tinted (light red wash + red text + red border). Stop / Disconnect / Delete.
  - `.subtle` — borderless, secondary-foreground. Toolbars, chrome-light actions (e.g. `Copy Logs`).
- **`PanelIconButton(icon:help:color:action:)`** — small icon-only button (22×22) with hover background; used for refresh, +, ×, map/pencil/trash, etc.
- **`PanelDivider`** — `Divider().padding(.horizontal, -20)` so it bleeds past the sidebar's 20 px inner padding for an edge-to-edge hairline.
- **`PanelSectionLabel(text:)`** — uppercase caption2, semibold, tracking 0.5, tertiary foreground. macOS Inspector convention.
- **`PanelContainer<Content>`** — rounded subtle-fill container with hairline border. Wraps `LocationsView` body.
- **`LiveStatusPill(label:color:pulses:isLoading:)`** — capsule with a colored dot. `pulses: true` (default) shows a radiating halo for active states; `pulses: false` for steady states (Connected, Idle, Error). `isLoading: true` swaps the dot for a tiny spinner — use for in-progress states (`.mounting`, `.connecting`, `.stopping`).
- **`StatusSection(rows:[Row])`** — lays out an array of pills horizontally. Used by `StatusPanel` (in `iOSPanel.swift`) for the dedicated device-+-simulation status zone at the top of the control panel.

### Toggle buttons (CTA pattern)

Apply to A / Stop Mocking, Simulate Route / Stop Route, A→B Linear / Stop A→B — these are **the same button** swapping label, action, and style based on `simulationStatus`:

- Idle: `.prominent`, label = action verb.
- Active (this one's running): `.destructive`, label = `Stop …`.
- Stopping: same style as active, `isLoading: true`, disabled, label = `Stopping…`.
- Other simulation active (e.g. A→B is running while looking at Simulate Route): disabled.

See `LocationSettingsPanel.simulateRouteButton` / `atoBButton` / `startStopSimulateButton` for the pattern.

### Spacing rhythm

Every top-level section in the control panel uses `.padding(.vertical, 14)` around `PanelDivider`s. This gives uniform 14 px breathing room above and below every hairline. Do not introduce one-off paddings (`.padding(.top, 6)` etc.); the rhythm is intentional and consistent across:

- StatusPanel
- iOSDeviceSettings / AndroidDeviceSettings
- Mode picker + control area in LocationSettingsPanel
- LocationsView
- Copy Logs button at the bottom

The sidebar VStack uses `spacing: 0`; gaps come exclusively from the section paddings, never from the parent VStack.

---

## UX Rules

### Optimistic status updates

When the user kicks off a mocking action, set `simulationStatus = .mocking` (or `.route` / `.fromAToB`) **synchronously** before the async device call. The button flips instantly to its `.destructive` state without waiting for a 100 ms – 1 s network round trip. Revert to `.idle` only on failure (in the `catch` branch of the async task).

See `LocationController.run(location:)` for the canonical pattern:

```swift
currentRunTask?.cancel()
if simulationStatus == .idle { simulationStatus = .mocking }
// ...kick off async work; revert to .idle in catch
```

### Mode-switch auto-stop

`handlePointsModeChange()` is called whenever `pointsMode` changes. If any simulation is currently mocking-active (`.route`, `.fromAToB`, or `.mocking`), it first `await stopSimulation(clearAnnotations: false)` and only then performs annotation cleanup (e.g. trimming Point B when switching to single). The whole block runs inside a `Task @MainActor` so the cleanup is sequenced *after* the async teardown — no race with the simulator process.

### Point A persistence on stop

For single-mode mocking, call `stopSimulation(clearAnnotations: false)` so Point A stays on the map and the user can re-apply without re-placing the pin. Route stops (`Simulate Route`, `A→B Linear`) keep the default `clearAnnotations: true` because A/B are tied to the route geometry.

### Apply to A flies the map

`setSelectedLocation()` (the Apply to A action) calls `centerVisibleOn(annotation.coordinate)` *before* `run(location:)`. The map flies to Point A — landing in the visible (un-covered) strip of the map — and *then* mocking starts. Keeps the user's eye on the location they're now mocking.

### Map centering must respect the side panel

The right side of the map is covered by the control panel when it's open. `LocationController.@Published var mapVisibleInsetRight: CGFloat` tracks that width; `ContentView` syncs it on `onAppear` and `onChange(of: showSidePanel)` using the single constant `sidePanelTotalWidth = 360`.

Every fly-to / fit-to-rect call funnels through one of two helpers on `LocationController`:

- `centerVisibleOn(_:)` — for a single coordinate (Point A placement, Apply to A, search picks, locate-me).
- `showVisibleMapRect(_:edgeMargin:)` — for arbitrary rects (Simulate Route bounds, A→B Linear bounds).

Both use `MKMapView.setVisibleMapRect(_:edgePadding:animated:)` with `NSEdgeInsets(right: mapVisibleInsetRight, ...)` so MapKit fits the content into the un-covered portion of the map. When the panel is closed, the inset is 0 and the helpers degrade to a normal full-window fit.

**Do not call `mapView.mkMapView.setRegion(_:animated:)` directly for user-initiated camera moves.** Use the helpers.

### Status zone

The top of the control panel surfaces device + simulation state as two horizontal `LiveStatusPill`s rendered by `StatusPanel` (`iOSPanel.swift`). Color encoding:

| State | Color | Pulse | Spinner |
|---|---|---|---|
| Idle | gray | no | no |
| Active (Connected / Mocking / Simulating …) | green | yes for sim, no for connected | no |
| In-progress (Connecting / Mounting / Stopping) | orange | no | yes |
| Error | red | no | no |

Animate state changes with `.easeInOut(duration: 0.25)`.

---

## Model invariants

### `Location.id` must be a stored UUID

`Location.id` is a stored `UUID` (not derived from `latitude`/`longitude`). This is required because:

1. Saving two locations at the same coordinates needs to produce two distinct rows in `ForEach(savedLocations, id: \.id)` (otherwise SwiftUI dedupes to one row).
2. `removeAll { $0.id == location.id }` must remove only the targeted row, not every same-coordinate sibling.

The `Decodable` init synthesizes a fresh UUID when older saved data lacks the field, so existing user data still decodes:

```swift
init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
    // ...
}
```

---

## Window / launch gotchas

### SPM-built executables and keyboard focus

The app supports two launch paths:

- Xcode (`open SimVirtualLocation.xcodeproj`) — produces a proper `.app` bundle with Info.plist; activation policy is `.regular` by default.
- Swift Package Manager (`open Package.swift` or `swift run`) — produces a bare executable with no bundle. macOS launches it as `.accessory`, so the main window can never become key and keyboard events are silently dropped (TextField won't accept input, arrow keys for joystick do nothing).

The fix lives in `Views/Main.swift`:

```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(nil)
            }
        }
    }
}
```

Wired in via `@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate` on `SimVirtualLocationApp`. Don't remove these — both launch paths depend on them.

### Worktrees and `project.pbxproj`

`SimVirtualLocation.xcodeproj/project.pbxproj` is in `.gitignore` (chosen to avoid frequent merge conflicts). Git worktrees do not inherit ignored files from the parent checkout, so a fresh worktree has no `project.pbxproj` — `xcode-build-server`, SweetPad, and direct Xcode opens all fail with cryptic errors.

When creating a new worktree, copy the file in:

```bash
cp ../../SimVirtualLocation.xcodeproj/project.pbxproj SimVirtualLocation.xcodeproj/project.pbxproj
```

SwiftPM (`swift build`) does not need this file.

### Logging (`Logic/Logger.swift`)
- All logging must go through `AppLogger.shared`. Helpers: `.debug(_:)`, `.info(_:)`, `.warn(_:)`, `.error(_:)` (each takes an `@autoclosure`).
- Output destinations:
  - stdout (level ≥ debug)
  - File at `~/Library/Logs/SimVirtualLocation/app.log` (rotated at 1 MB × 5 backups: `app.log.1` … `app.log.5`)
  - An observer registered by `LocationController` that pushes the most recent 500 entries to `@Published var logs: [LogEntry]` for the SwiftUI debug panel.
- Format: `[<ISO8601>] [<LEVEL>] [<File:Line>] <message>`.
- All log messages run through `Sanitizer.sanitize(_:)` which redacts:
  - The user's home directory (replaced by `~`)
  - `/Users/<name>/...` paths
  - 25-/40-char hex UDIDs and standard UUIDs
  - IPv6 link-local addresses (e.g. `fe80::...%enX`)
- **Never** call `print(...)` directly. Use `AppLogger` so output is sanitized and persisted.

### Data Flow
1. User interacts with SwiftUI views or triggers global key events (managed in `ContentView`).
2. Views call methods on `@ObservedObject LocationController`.
3. LocationController updates `@Published` properties (triggers UI updates) and updates map annotations (e.g., `addLocation` handles placing Point A and conditionally triggering a run).
4. LocationController delegates command execution to `Runner` only when `isDeviceReady` is true.
5. Runner runs external processes asynchronously and reports back via callbacks/return values.
6. All diagnostics (controller, runner, delegates) flow through `AppLogger`.

---

## Common Tasks

### Implementing Global Keyboard Shortcuts
- Define `NSEvent.addLocalMonitorForEvents` within the `onAppear` modifier of a root view like `ContentView`.
- Use SwiftUI's `@FocusState` to check if a `TextField` is active. If true, return the event unmodified to avoid intercepting user typing.
- Always remember to remove the monitor in `onDisappear`.
- Delegate complex logic (like processing arrow keys for joystick movement) to the appropriate controller (e.g., `LocationController.handleKeyEvent`).

### Joystick & Continuous Map Interaction
- For features requiring high-frequency input (like a joystick), use a timer (e.g., `Timer.scheduledTimer(withTimeInterval: 0.016, ...)`) to smoothly animate `MKPointAnnotation` coordinates on the map.
- Implement a **debounce mechanism** (e.g., 0.1s timer after keys are released) before actually sending the final location update to the physical device. This prevents command flooding and timeout errors.
- Always separate the visual map update from the actual hardware location update. Use computed properties like `isDeviceReady` to safely gate the hardware update.

### Adding a New Feature
1. Create model in `Models/` if new data structure needed
2. Add business logic to `LocationController` or create new controller
3. Create SwiftUI view in `Views/`
4. Connect view to controller using `@ObservedObject` or `@EnvironmentObject`
5. Update `ContentView` to include new view if needed

### Working with External Commands
- Use `Runner.taskForIOS(args:)` for pymobiledevice3 commands (note: it now throws when the binary is missing instead of taking a `showAlert` callback). Catch the error at the call site if you need a UI alert.
- Use `Runner.taskForAndroid(args:adbPath:)` for adb commands.
- Always handle errors with `try/catch`. For UI alerts, call `LocationController.showAlert(_:)`.
- Log command execution via `AppLogger.shared.debug(...)` (do **not** call `print` directly).

### Debugging
- All diagnostics: `AppLogger.shared.debug(...)`/`info(...)`/`warn(...)`/`error(...)`.
- The in-app log panel (`d` key) shows the last 500 entries; full history is at `~/Library/Logs/SimVirtualLocation/app.log` (rotated).
- External command output is captured via `Pipe()` objects.

---

## Important Notes

### Dependencies
- **pymobiledevice3:** Required for iOS device support. Auto-detected in `~/Library/Python/`
- **adb:** Required for Android support. User must specify path in settings
- **xcrun simctl:** Built-in macOS tool for iOS Simulator support

### File Locations
- Helper APK: `SimVirtualLocation/helper-app.apk` (bundled Android app)
- Virtual environment: `SimVirtualLocation/.venv/` (Python venv, gitignored)
- Assets: `SimVirtualLocation/Assets.xcassets/`
- Entitlements: `SimVirtualLocation/SimVirtualLocation.entitlements`

### UserDefaults Keys
- `device_type`: Selected device type (0=iOS, 1=Android)
- `adb_path`: Path to adb executable
- `adb_device_id`: Android device ID
- `is_emulator`: Boolean for Android emulator mode
- `xcode_path`: Path to Xcode.app
- `saved_locations`: JSON-encoded array of saved locations

---

## Git Workflow

### Ignored Files
- `SimVirtualLocation.xcodeproj/xcuserdata/` (user-specific Xcode settings)
- `DerivedData/` (build artifacts)
- `buildServer.json` (machine-specific BSP config)
- `.DS_Store` files

### Commit Messages
- Use clear, descriptive commit messages
- Start with verb: "Add", "Fix", "Update", "Remove", "Refactor"
- Example: "Add support for iOS 17+ RSD connection"

---

**Last Updated:** 2026-05-05  
**Project Version:** Latest (check git tags/releases)
