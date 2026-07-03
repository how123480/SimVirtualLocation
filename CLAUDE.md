# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Debug build (no code signing required)
xcodebuild -project SimVirtualLocation.xcodeproj \
  -scheme SimVirtualLocation \
  -configuration Debug \
  -destination 'platform=macOS' \
  build \
  CODE_SIGNING_ALLOWED=NO

# Clean
xcodebuild clean -project SimVirtualLocation.xcodeproj -scheme SimVirtualLocation

# Build installer package (.pkg)
./scripts/build-pkg.sh
```

No test suite currently exists (`ENABLE_TESTABILITY = YES` is set but unused).

## Architecture

SwiftUI macOS app (11+) for spoofing iOS/Android device GPS. External tools do the heavy lifting — the app is an orchestration layer.

**Source layout:** `SimVirtualLocation/{Logic,Models,Views}/`

### Key components

- **`LocationController`** (`Logic/LocationController.swift`) — `@MainActor ObservableObject`. Central coordinator: owns device/simulation state, drives `Runner` and `GPXPlayback`, manages the `MKMapView` delegate, and handles `CLLocationManagerDelegate` callbacks. All `@Published` UI state lives here.
- **`Runner`** (`Logic/Runner.swift`) — `async/await` wrapper around `Process`. Runs `xcrun simctl`, `pymobiledevice3`, and `adb`. Provides both one-shot `set` calls and long-running `play` calls for GPX.
- **`GPXGenerator` / `GPXPlayback`** (`Logic/GPXGenerator.swift`) — `GPXGenerator` converts a polyline + speed (km/h) into a GPX 1.1 file sampled at 1 trkpt/s, written to `~/Library/Application Support/SimVirtualLocation/routes/` (max 50 files). `GPXPlayback` is a `@MainActor` lifecycle wrapper around `pymobiledevice3 ... simulate-location play`; `start(...)` cancels any in-flight process before launching a new one.
- **`AppLogger`** (`Logic/Logger.swift`) — singleton; all log calls must go through `.debug/info/warn/error`. **Never use `print()`**. Sanitizes home dir, UDIDs, UUIDs, and IPv6 link-local addresses before writing to `~/Library/Logs/SimVirtualLocation/app.log` (1 MB × 5 rotations).
- **`MapView`** (`Views/MapView.swift`) — `NSViewRepresentable` wrapper for `MKMapView`.
- **`ContentView`** (`Views/ContentView.swift`) — root view; owns all global key event monitors (`Esc`, `d`, arrow keys). Uses `@FocusState` to avoid intercepting TextField input. Defines the single source of truth `sidePanelTotalWidth: CGFloat = 360` used for both the map zoom-button trailing offset and for syncing `LocationController.mapVisibleInsetRight`.
- **`Views/DesignSystem.swift`** — the entire visual language lives here. **All buttons, dividers, section labels, status indicators, and container backgrounds must come from this file.** Do not reach for `.bordered`, `.borderedProminent`, raw `Color.gray`, or one-off `RoundedRectangle` chrome in feature code.
- **`AppDelegate`** (`Views/Main.swift`) — sets `NSApp.setActivationPolicy(.regular)` in `applicationWillFinishLaunching`. Required because SPM-built executables (`swift run`, `open Package.swift`) otherwise launch as `.accessory` and their windows can never become key, so keyboard events get silently dropped.

### Status enums (`Models/DeviceStatus.swift`)

- `DeviceStatus`: `.idle | .checkingDeveloperMode | .waitingAuthorization | .mounting | .connecting | .connected | .error(String)`. Use `.isReady` to gate hardware updates; `.displayText` for UI labels.
- `SimulationStatus`: `.idle | .route | .fromAToB | .mocking`. Use `.isMockingActive` for joystick live-send logic; `isRouteSimulationActive` (computed on `LocationController`) locks A/B annotations during route playback.

### GPX playback flow (iOS physical device, Route/A→B)

1. `simulateRoute()` / `simulateFromAToB()` build `tracks` (visual puck path) and `currentPolyline` (full GPX source).
2. `kickoffGPXPlaybackIfNeeded()` → `GPXGenerator.render(...)` writes the file → `GPXPlayback.start(...)` launches `pymobiledevice3 ... simulate-location play`.
3. The local 0.1 s movement timer skips `run(location:)` while `shouldUseGPXPlayback` is true (device path) so the play process and the per-tick sender never double-drive the device. If the play process dies unexpectedly, `GPXPlayback.onUnexpectedExit` → `handleGPXPlaybackUnexpectedExit()` recovers the tunnel if needed and restarts playback from the puck's current position (max 3 consecutive restarts).
4. Speed slider changes trigger a 0.4 s debounce → `remainingPolyline()` from the puck's current position → new GPX written → old process SIGTERMed → new process started. The puck does not jump back to A.
5. iOS Simulator and Android use per-tick `set` calls instead (no GPX equivalent).

## Critical Code Rules

- **No `DispatchQueue`** — use `Task { @MainActor in ... }` for hops to main actor, `Task.detached(priority: .userInitiated)` for genuine background work.
- **No `print()`** — use `AppLogger.shared`.
- **No force-unwrap** (`!`) unless the value is provably non-nil.
- `[weak self]` in all `Timer` callbacks and async closures that close over the controller.
- New status cases must add a `displayText` computed property so views never format strings inline.
- `// MARK: -` sections order: Enums → Public Properties → Publishers → Private Properties → Init → Public Methods → Protocol Conformance → Private Methods.

## UI Design System (`Views/DesignSystem.swift`)

The control panel follows a strict macOS-native visual language. Reuse the existing tokens and components; do not invent ad-hoc chrome.

**Tokens — `PanelTheme`:**
- All fills are `Color.primary.opacity(...)` so they auto-adapt to light/dark mode. **Never hardcode `Color.gray`, `Color.white`, `NSColor.windowBackgroundColor` etc. for UI surfaces.**
- `containerFill`, `rowFill`, `buttonFill`/`Hover`/`Pressed`, `separator`, `radius` (= 6), `radiusContainer` (= 10), `textPrimary` / `textSecondary` / `textTertiary` — three semantic text levels, no others.

**Buttons — always use `PanelButton`** (text centered via `frame(maxWidth: .infinity)`). Four styles:
- `.standard` — subtle neutral fill (most controls).
- `.prominent` — accent-tinted (NOT solid blue). Reserved for the primary CTA in a section.
- `.destructive` — red-tinted. Used for Stop / Disconnect / Delete.
- `.subtle` — borderless, secondary-foreground. Toolbars and chrome-light actions (e.g. `Copy Logs`).

**Toggle buttons** (Apply to A / Stop Mocking, Simulate Route / Stop Route, A→B Linear / Stop A→B): **same button** swaps label + style based on `simulationStatus` — `.prominent` when idle, `.destructive` when active. Use `isLoading: true` while in `.stopping`.

**Other components:**
- `PanelIconButton` — small icon-only button (refresh, +, trash, etc.). Built-in hover bg.
- `PanelDivider` — full-bleed hairline (negative horizontal padding compensates for the sidebar's 20 px inner padding).
- `PanelSectionLabel` — uppercase, caption2, semibold, tracking 0.5, tertiary foreground.
- `PanelContainer<Content>` — rounded subtle-fill container with hairline border (Saved Locations group).
- `LiveStatusPill` — capsule with a colored dot. `pulses: Bool` for active states (default true), `isLoading: Bool` replaces the dot with a spinner.
- `StatusSection` — array of `LiveStatusPill`s laid out horizontally; used by `StatusPanel` in `iOSPanel.swift` to render device + simulation status at the top of the control panel.

**Spacing rhythm:** every top-level section in the control panel uses `.padding(.vertical, 14)`, with `PanelDivider` between sections. Do not introduce one-off paddings; keep the rhythm consistent.

## UX Rules

- **Optimistic status updates.** When kicking off any mocking action, set the `simulationStatus` synchronously (e.g. `.mocking`) *before* the async device call, so the UI flips instantly. Revert to `.idle` only on failure. See `run(location:)` for the pattern.
- **Mode-switch auto-stop.** `handlePointsModeChange()` first awaits `stopSimulation(clearAnnotations: false)` if any mocking is active (covers `.route`, `.fromAToB`, `.mocking`), then performs annotation cleanup. Sequenced in a `Task @MainActor` so the cleanup runs *after* teardown completes — no race with the simulator process.
- **Point A persistence.** When the user stops single-point mocking, call `stopSimulation(clearAnnotations: false)` so Point A stays on the map and can be re-applied without re-placing the pin. Route stops (which discard A/B by design) keep the default `clearAnnotations: true`.
- **Map centering must respect the side panel.** Every fly-to / fit-to-rect call funnels through one of two helpers on `LocationController`:
  - `centerVisibleOn(_:)` — for a single coordinate (Point A placement, Apply to A, search-result pick, locate-me).
  - `showVisibleMapRect(_:edgeMargin:)` — for arbitrary rects (Simulate Route bounds, A→B Linear bounds).
  Both consult `@Published var mapVisibleInsetRight: CGFloat`, which `ContentView` syncs from `showSidePanel`. When the panel is closed the inset is 0 and the helpers degrade to a normal full-window fit. **Do not call `mapView.setRegion(_:animated:)` directly** for user-initiated camera moves.
- **Status zone at top of control panel.** Device state + simulation state are surfaced as two horizontal `LiveStatusPill`s in `StatusPanel` (iOSPanel.swift). Green = active/ok, orange + spinner = in-progress, red = error, gray + `pulses: false` = idle. Animate pill changes with `.easeInOut(duration: 0.25)`.

## Model invariants

- `Location.id` is a **stored `UUID`**, not derived from coordinates. Required so duplicate-coordinate saves render as separate rows in `ForEach` and `removeAll { $0.id == ... }` only deletes the targeted row. The `Decodable` init synthesizes a fresh UUID when older saved data lacks the field (backward-compat).

## Worktree gotcha

`SimVirtualLocation.xcodeproj/project.pbxproj` is in `.gitignore`. When checking out a new worktree, `xcode-build-server` / SweetPad / direct Xcode opens will fail until you copy `project.pbxproj` from the main checkout into the worktree:

```bash
cp ../../SimVirtualLocation.xcodeproj/project.pbxproj SimVirtualLocation.xcodeproj/project.pbxproj
```

## External Dependencies

| Tool | Used for | How detected |
|------|----------|--------------|
| `pymobiledevice3` | iOS physical device commands | Auto-detected in `~/Library/Python/` |
| `xcrun simctl` | iOS Simulator | Built into macOS |
| `adb` | Android | User-specified path in settings |

Setup: `./scripts/setup.sh` installs `uv` and `pymobiledevice3`.
Check environment: `./scripts/check-env.sh`.

## UserDefaults Keys

`device_type` (0=iOS, 1=Android), `adb_path`, `adb_device_id`, `is_emulator`, `xcode_path`, `saved_locations` (JSON).
