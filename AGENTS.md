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
- All inline comments are written in **Traditional Chinese**. Doc comments for type-level public APIs may stay in English when they document protocol semantics, but everything inside method bodies should be Chinese.
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
- **LocationController:** Main `@MainActor` business logic coordinator, owns `MapView` and `Runner`. Maintains `deviceStatus: DeviceStatus` (replaces the legacy `Bool isDeviceActive` + `String tunnelStatus`) and `simulationStatus: SimulationStatus` (replaces `Bool isSimulating` + `simulationType`). Computed property `isDeviceReady` ensures location updates only fire when the iOS tunnel is connected.
- **Runner:** Handles execution of external commands (pymobiledevice3, adb, xcrun) using `async/await`. No `DispatchQueue` left.
- **AppLogger:** Singleton logger (see "Logging" below).
- **MapView:** Wraps `MKMapView` in SwiftUI using `NSViewRepresentable`.
- **ContentView:** Root view assembling all UI components. Serves as the centralized manager for global keyboard shortcuts (`Esc` to unfocus, `d` for debug mode, arrow keys for joystick), utilizing `@FocusState` to prevent conflicts with text input fields.

### Status Enums (`Models/DeviceStatus.swift`)
- `DeviceStatus`: `.idle`, `.checkingDeveloperMode`, `.waitingAuthorization`, `.mounting`, `.connecting`, `.connected`, `.error(String)`. Use `deviceStatus.displayText` whenever a UI button needs to show progress; use `deviceStatus.isReady` to gate hardware updates.
- `SimulationStatus`: `.idle`, `.route`, `.fromAToB`, `.mocking`. The joystick uses `simulationStatus.isMockingActive` to decide whether arrow keys should send live updates to the hardware.
- When you add a new status, also add the localized `displayText` so UI never has to format strings inline.

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

**Last Updated:** 2024-02-03  
**Project Version:** Latest (check git tags/releases)
