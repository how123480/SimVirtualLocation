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

No test suite currently exists (`ENABLE_TESTABILITY = YES` is set but unused). Verification = clean build + manual device scenarios.

## Architecture

SwiftUI macOS app (12+) for spoofing iOS GPS (Simulator + physical devices). External tools do the heavy lifting — the app is an orchestration layer around `pymobiledevice3`.

**Source layout:** `SimVirtualLocation/{Logic,Models,Views,Views/iOS}/`

### Key components

- **`LocationController`** (`Logic/LocationController.swift`, ~1700 lines) — `@MainActor ObservableObject`. Central coordinator: owns device/simulation state, drives `MobileDeviceClient` and `GPXPlayback`, manages the `MKMapView` delegate and `CLLocationManagerDelegate`, runs the 30 s device health check and the joystick. All `@Published` UI state lives here.
- **`MobileDeviceClient`** (`Logic/MobileDeviceClient.swift`, ~1000 lines) — the single abstraction over `pymobiledevice3`. Contains four units:
  - `MobileDeviceClient` (`@MainActor`) — device listing, Developer Mode, mount, set/clear location, GPX play, tunneld lifecycle, and the persistent-helper routing.
  - `ProcessRunner` — one-shot process execution. `static execute(executable:args:timeout:)` runs ANY executable (termination handler installed *before* launch, stdout/stderr drained concurrently, SIGKILL on timeout); instance `run(args:timeout:)` delegates to it for pymobiledevice3. `runDiscardingOutput`/`runUntilStdoutReady` return a `LongRunningHandle` (SIGTERMs the descendant tree on `stop()`, exposes `wasStoppedIntentionally` + a termination callback).
  - `TunneldSupervisor` — static utility for the `pymobiledevice3 remote tunneld` root daemon (pgrep liveness, HTTP readiness on `127.0.0.1:49151`, osascript admin launch/kill). The daemon survives app quits; it is launched at most once per Mac boot.
  - `TunnelRecoveryCoordinator` — the silent reconnect ladder (L1 verify → L2 backoff-poll → L3 sudo force-restart), single-flight so concurrent triggers join one attempt.
- **`LocationHelperScript` / `LocationHelperClient`** (`Logic/LocationHelperScript.swift`, `Logic/LocationHelperClient.swift`) — the persistent location helper (see connection stack below).
- **`GPXGenerator` / `GPXPlayback`** (`Logic/GPXGenerator.swift`) — `GPXGenerator` converts a polyline + speed (km/h) into a GPX 1.1 file (1 trkpt/s) under `~/Library/Application Support/SimVirtualLocation/routes/` (max 50 kept). `GPXPlayback` (`@MainActor`) wraps `pymobiledevice3 … simulate-location play` with a **generation token** (overlapping `start()` calls can never leave two play processes alive) and reports unexpected process death via `onUnexpectedExit`.
- **`Runner`** (`Logic/Runner.swift`) — now only the iOS Simulator path (posts distributed notifications via `NotificationSender`). Per-tick sends on the non-GPX path are throttled by the fixed `Constants.runnerUpdateInterval` (1.5 s) in `LocationController` — there is no user-facing update-interval setting.
- **`AppError` / `ErrorHandler`** (`Logic/AppError.swift`, `Logic/ErrorHandler.swift`) — every fallible operation surfaces a typed `AppError`; `ErrorHandler` decides log/alert/state-reset. `AppError.from(stderr:context:)` classifies pymobiledevice3 stderr; `isTunnelDrop == true` (no-route-to-host, connection refused/reset, tunneld unreachable, command timeout, …) routes into silent tunnel recovery instead of alerting. **`presentAlert` is presentation-only — it must never mutate `simulationStatus`** (alerts fire for benign reasons during a running simulation; any status reset happens explicitly at the call site or via `requiresStateReset` → `resetAllState`).
- **`AppLogger`** (`Logic/Logger.swift`) — singleton; all logging goes through `.debug/info/warn/error`. **Never use `print()`**. Every message is sanitized at write time (home dir, UDIDs, UUIDs, IPv6 link-local) before hitting `~/Library/Logs/SimVirtualLocation/app.log` (1 MB × 5 rotations) and the in-app log panel — so interpolating a UDID or path into a log message is safe.
- **`MapView`** (`Views/MapView.swift`) — `NSViewRepresentable` wrapper for `MKMapView`.
- **`ContentView`** (`Views/ContentView.swift`) — root view; owns all global key event monitors (`Esc`, `d`, arrow keys). Uses `@FocusState` to avoid intercepting TextField input. Layout is a flat `ZStack` of full-size layers: map (`.ignoresSafeArea()`, bleeds under the hidden title bar), debug log (bottom-leading), zoom cluster (bottom-trailing), search column (top-leading — stays inside the safe area so it clears the traffic lights), and the side panel: a **full-height inspector** flush with the trailing window edge, with the chevron collapse handle (24×60 tab) vertically centered on its leading edge (`.thickMaterial`, leading hairline, no shadow/no radius). Defines the single source of truth `sidePanelTotalWidth: CGFloat = 340` (300 content + 2×20 padding) used for the floating-control trailing offsets and for syncing `LocationController.mapVisibleInsetRight`.
- **`Views/DesignSystem.swift`** — the entire visual language lives here. **All buttons, dividers, section labels, status indicators, and container backgrounds must come from this file.** Do not reach for `.bordered`, `.borderedProminent`, raw `Color.gray`, or one-off `RoundedRectangle` chrome in feature code.
- **`AppDelegate`** (`Views/Main.swift`) — sets `NSApp.setActivationPolicy(.regular)` in `applicationWillFinishLaunching`. Required because SPM-built executables otherwise launch as `.accessory` and their windows can never become key, so keyboard events get silently dropped. The `WindowGroup` uses `.windowStyle(.hiddenTitleBar)` — the map bleeds under the title-bar strip (traffic lights float over it, Maps-style); the hidden strip remains the window-drag region, and SwiftUI's top safe area keeps overlays clear of the traffic lights.

### iOS device connection stack (RSD, iOS 17+)

Understanding this flow requires reading `LocationController` + `MobileDeviceClient` + `LocationHelperClient` together:

1. **Connect** (`startDevice` → `connectViaTunneld`): checks Developer Mode, ensures tunneld is running (`ensureTunneldRunning(allowLaunch: true)` — the ONLY inline path allowed to sudo-launch tunneld), then warms up the location helper in the background. iOS ≤16 uses the legacy path (`mountDeveloperImage`, one-shot CLI commands, no tunnel).
2. **set/clear go through the persistent helper first.** `pymobiledevice3` 9.5.1's `dvt simulate-location set` intentionally never exits (`wait_return`) — one-shot spawns would leak a hung Python process per tick. Instead, a Python helper (source embedded in `LocationHelperScript.source`, written to Application Support at runtime, run with the interpreter parsed from pymobiledevice3's shebang) holds ONE DVT `LocationSimulation` connection and serves line-JSON `set`/`clear`/`ping` over stdin/stdout. `LocationHelperClient` enforces FIFO request/response pairing, 5 s command timeouts (timeout ⇒ fail-all-pending + kill + auto-restart), per-spawn generation guards, a 3-restart cap with last-coordinate re-send, and device-UDID ownership (a picker switch shuts the old helper down). Helper death auto-clears the device's simulated location (iOS drops simulation when the DTX connection dies).
3. **Fallback:** if the helper can't run (sticky `helperUnsupported`, or a 30 s start-failure cooldown), RSD `set` falls back to `runUntilStdoutReady` — the set process is kept as a managed `LongRunningHandle` (readiness = first stdout byte, needs `PYTHONUNBUFFERED=1`), stopped on the next set/clear.
4. **Health check** (every 30 s while `.connected`): USB presence via `usbmux list` AND `verifyTunnel` (tunneld's JSON must list the udid — a 200 from tunneld is not enough). Two consecutive failures trigger the recovery ladder; only if the ladder fails does the app tear down and alert.
5. **Sudo policy:** password prompts may only originate from the Connect button or the recovery ladder's L3 (`forceRestartTunneld`) — never from per-tick sends or Stop. Inline commands that find tunneld dead throw `tunneldNotReady` (a tunnel-drop) and let recovery handle it.
6. **Stop:** `stopSimulation` kills swift-side tasks + play process, clears via the helper (near-instant), then `pkill -f simulate-location` (which deliberately does NOT match `location-helper.py`, so the warm helper survives). Teardown clears are best-effort — tunnel-drop errors log instead of alerting. The final log line is timed: `Simulation stopped (N.NNs)`.

### Status enums (`Models/DeviceStatus.swift`)

- `DeviceStatus`: `.idle | .checkingDeveloperMode | .waitingAuthorization | .mounting | .connecting | .connected | .reconnecting | .error(String)`. `.isReady` gates hardware updates (only `.connected`); `.reconnecting` is the silent-recovery state and is NOT ready — this is what stops the health-check timer and per-tick GPX gating during recovery.
- `SimulationStatus`: `.idle | .route | .fromAToB | .routePaused | .fromAToBPaused | .mocking | .stopping`. `.isMockingActive` covers everything except `.idle`/`.stopping` (so `stopSimulation` is idempotent); `isRouteSimulationActive` (computed on `LocationController`) locks A/B annotations during route playback; paused states still own the device location.

### GPX playback flow (iOS physical device, Route/A→B)

1. `simulateRoute()` / `simulateFromAToB()` build `tracks` (visual puck path) and `currentPolyline` (full GPX source).
2. `kickoffGPXPlaybackIfNeeded()` → `GPXGenerator.render(...)` runs **detached** (sampling long low-speed routes takes seconds) guarded by `gpxKickoffGeneration` so a stale render can't start playback → `GPXPlayback.start(...)` launches `pymobiledevice3 … simulate-location play`.
3. The local 0.1 s movement timer skips `run(location:)` while `shouldUseGPXPlayback` is true (device path) so the play process and the per-tick sender never double-drive the device. If the play process dies unexpectedly, `GPXPlayback.onUnexpectedExit` → `handleGPXPlaybackUnexpectedExit()` recovers the tunnel if needed and restarts playback from the puck's current position (max 3 consecutive restarts, cap reset per kickoff).
4. Speed slider changes trigger a 0.4 s debounce → `remainingPolyline()` from the puck's current position → new GPX written → old process SIGTERMed → new process started. The puck does not jump back to A.
5. iOS Simulator uses per-tick `set` calls instead (no GPX equivalent).

## Critical Code Rules

- **No `DispatchQueue`** — use `Task { @MainActor in ... }` for hops to main actor, `Task.detached(priority: .userInitiated)` for genuine background work, `ProcessRunner.execute` for subprocess calls.
- **No `print()`** — use `AppLogger.shared` (auto-sanitized; see above).
- **No force-unwrap** (`!`) unless the value is provably non-nil (`urls(for:in:).first!` is the accepted exception).
- `[weak self]` in all `Timer` callbacks and async closures that close over the controller.
- New status cases must add a `displayText` computed property so views never format strings inline.
- `// MARK: -` sections order: Enums → Public Properties → Publishers → Private Properties → Init → Public Methods → Protocol Conformance → Private Methods.
- Concurrency around processes: install `terminationHandler` BEFORE `run()`; never read pipes only after exit (64 KB deadlock); bound every external command with a timeout.

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
- `PanelContainer<Content>` — rounded subtle-fill container with hairline border (used for transient forms like the add-location form).
- `LiveStatusPill` — capsule with a colored dot. `pulses: Bool` for active states (default true), `isLoading: Bool` replaces the dot with a spinner. Used for the simulation state on the SIMULATION section header.
- `MapOverlayChrome` (`.mapOverlayChrome()`) — unified chrome for everything floating over the map (search bar, results, zoom cluster, panel toggle, debug log).
- `PanelEmptyState` — unified empty-state block (icon + caption title + optional caption2 hint) for every empty list/popover. No ad-hoc empty-state VStacks.

**Dialog conventions** (alerts/popovers must follow these):
- Alert titles are short Title Case phrases ("Rename Location", "Enter Coordinates") — never interpolate user content or long messages into the title. The global alert (`Alert` modifier in ContentView) titles with the app's `CFBundleName` and puts `alertText` in the `message:` body.
- Input alerts: affirmative button first (verb matching the action: Set / Rename / Add), then `Button("Cancel", role: .cancel)`. Rename TextField placeholder is always "Name" (field is prefilled with the current name).
- Popovers: row list → `Divider()` → one subtle utility footer row ("Manage Labels…", "Refresh List"); rows use `.padding(.horizontal, 10).padding(.vertical, 6)`; empty content uses `PanelEmptyState`.

**Spacing rhythm:** every top-level section in the control panel uses `.padding(.vertical, 14)`, with `PanelDivider` between sections. Do not introduce one-off paddings; keep the rhythm consistent.

## UX Rules

- **Optimistic status updates.** When kicking off any mocking action, set the `simulationStatus` synchronously (e.g. `.mocking`) *before* the async device call, so the UI flips instantly. Revert to `.idle` only on failure. See `run(location:)` for the pattern.
- **Mode-switch is vetoed while mocking.** The mode `Picker` binds its setter to `requestPointsModeChange(_:)`, **never directly to `pointsMode`**. That gate refuses the change when `simulationStatus.isMockingActive` (shows an alert, leaves `pointsMode` unchanged), so the running simulation is never torn down and there is no picker-revert race. `pointsMode.didSet` → `handlePointsModeChange` therefore only ever runs for an allowed change and just does the annotation/overlay cleanup for the new mode.
- **Point A persistence.** When the user stops single-point mocking, call `stopSimulation(clearAnnotations: false)` so Point A stays on the map and can be re-applied without re-placing the pin. Route stops (which discard A/B by design) keep the default `clearAnnotations: true`.
- **Map centering must respect the side panel.** Every fly-to / fit-to-rect call funnels through one of two helpers on `LocationController`:
  - `centerVisibleOn(_:)` — for a single coordinate (Point A placement, Apply to A, search-result pick, locate-me).
  - `showVisibleMapRect(_:edgeMargin:)` — for arbitrary rects (Simulate Route bounds, A→B Linear bounds).
  Both consult `@Published var mapVisibleInsetRight: CGFloat`, which `ContentView` syncs from `showSidePanel`. **Do not call `mapView.setRegion(_:animated:)` directly** for user-initiated camera moves.
- **Status is contextual, not a zone.** Device state lives on the **device card** (`iOSDeviceSettings.swift`): status dot + "iOS x.y · Connected" subtitle (mini spinner while transitioning, red text + `.help` tooltip for errors). Clicking the card opens a popover picker (device/simulator list + Refresh List row); the card is disabled while `deviceStatus.isActive`, like the old picker. Simulation state is a single `LiveStatusPill` on the SIMULATION section header (`LocationSettingsPanel.swift`). Green = active/ok, orange + spinner = in-progress, red = error, gray + `pulses: false` = idle. Animate status changes with `.easeInOut(duration: 0.25)`.

## Model invariants

- `Location.id` is a **stored `UUID`**, not derived from coordinates. Required so duplicate-coordinate saves render as separate rows in `ForEach` and `removeAll { $0.id == ... }` only deletes the targeted row. The `Decodable` init synthesizes a fresh UUID when older saved data lacks the field (backward-compat).

## Project-file gotchas

- **`project.pbxproj` is gitignored** but required to build. New Swift files must be registered manually (no synchronized folders): one `PBXBuildFile` line, one `PBXFileReference` line, one group-children entry, one Sources-phase entry. The project uses synthetic `AA0000XX…A1`-style IDs for hand-added files — pick unused ones.
- **Worktrees:** a fresh worktree lacks `project.pbxproj`; copy it from the main checkout (`cp ../../SimVirtualLocation.xcodeproj/project.pbxproj SimVirtualLocation.xcodeproj/project.pbxproj`) or `xcode-build-server`/SweetPad/Xcode fail.
- **SourceKit false errors:** after pbxproj edits, the IDE often reports bogus "Cannot find X in scope" diagnostics across files while `xcodebuild` succeeds. Trust the build; restart Xcode/xcode-build-server to clear.

## External Dependencies

| Tool | Used for | How detected |
|------|----------|--------------|
| `pymobiledevice3` (9.5.x) | iOS physical device commands + tunneld daemon | `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, then `which` |
| pymobiledevice3's venv Python | runs the embedded location helper | parsed from the pymobiledevice3 executable's shebang |
| `xcrun simctl` | iOS Simulator listing | built into macOS |

Setup: `./scripts/setup.sh` installs `uv` and `pymobiledevice3`. Check environment: `./scripts/check-env.sh`.

The pymobiledevice3 **library** API (tunneld lookup, `DvtProvider`, `LocationSimulation`) is consumed by the embedded helper script and changes between versions — `LocationHelperScript.source` targets 9.5.x; an `ImportError` makes the helper exit 3 and the app falls back to CLI one-shots for the rest of the run.

## UserDefaults Keys

`xcode_path`, `saved_locations` (JSON), `location_labels` (JSON).
