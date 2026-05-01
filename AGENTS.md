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
- Use `async/await` for asynchronous operations
- Mark async functions with `async throws` when appropriate
- Use `Task { @MainActor in ... }` for main thread updates
- Use `DispatchQueue` for background work when needed (legacy pattern)
- Example: `func refreshDevices() async { ... }`

### Error Handling
- Use `try/catch` for operations that can fail
- Show user-friendly alerts via `showAlert(_ text: String)` method
- Log errors to console with `print()` for debugging
- Custom errors should conform to `Error` and `CustomStringConvertible`
- Example:
  ```swift
  do {
      try task.run()
  } catch {
      showAlert(error.localizedDescription)
      return
  }
  ```

### Optional Handling
- Use `guard let` for early returns: `guard let location = locationManager.location else { return }`
- Use `if let` for conditional unwrapping when needed
- Use optional chaining for safe property access: `device?.id`
- Avoid force unwrapping (`!`) unless absolutely certain value exists

### Closures
- Use trailing closure syntax when it's the last parameter
- Use `[unowned self]` or `[weak self]` capture lists to prevent retain cycles
- Prefer `[unowned self]` in contexts where self is guaranteed to exist
- Example: `timer = Timer.scheduledTimer(...) { [unowned self] timer in ... }`

### Comments
- Write comments for complex logic or non-obvious behavior
- Avoid redundant comments that just restate the code
- Use `// MARK:` to organize code sections
- Document public API with clear descriptions

---

## Architecture Patterns

### App Structure
- **Main.swift:** App entry point with `@main` and SwiftUI `App` protocol
- **Controllers:** Business logic classes (e.g., `LocationController`) conforming to `ObservableObject`
- **Views:** SwiftUI views organized by feature (iOS/, Android/, Map, etc.)
- **Models:** Data structures (Device, Simulator, Track, Location, LogEntry)
- **Logic:** Utility classes (Runner, NotificationSender)

### Key Components
- **LocationController:** Main business logic coordinator, owns `MapView` and `Runner`. Manages state such as `isDeviceReady` to ensure location updates (via joystick, map click, or search) are only sent to the device if it has been started and successfully connected.
- **Runner:** Handles execution of external commands (pymobiledevice3, adb, xcrun)
- **MapView:** Wraps `MKMapView` in SwiftUI using `NSViewRepresentable`
- **ContentView:** Root view assembling all UI components. Serves as the centralized manager for global keyboard shortcuts (e.g., `Esc` to unfocus, `d` for debug mode, and arrow keys for joystick movement), utilizing `@FocusState` to prevent conflicts with text input fields like the Search Bar.

### Data Flow
1. User interacts with SwiftUI views or triggers global key events (managed in `ContentView`).
2. Views call methods on `@ObservedObject LocationController`.
3. LocationController updates `@Published` properties (triggers UI updates) and updates map annotations (e.g., `addLocation` handles placing Point A and conditionally triggering a run).
4. LocationController delegates command execution to `Runner` only when `isDeviceReady` is true.
5. Runner executes external processes and reports results via callbacks.

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
- Use `Runner.taskForIOS()` for pymobiledevice3 commands
- Use `Runner.taskForAndroid()` for adb commands
- Always handle errors with `try/catch` and show user alerts
- Log command execution with `log()` method
- Example in `LocationController.swift` (mountDeveloperImage, runOnAndroid)

### Debugging
- Use `print()` for console logging during development
- Use `log(_ message:)` to add entries to the in-app log viewer
- Check `LocationController.logs` array for runtime diagnostics
- External command output captured via `Pipe()` objects

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
