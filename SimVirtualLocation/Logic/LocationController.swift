//
//  LocationController.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 21.02.2022.
//
//  This class is the main coordination layer of the App:
//  - Maintain UI state (connected devices, simulation status, search results, etc.)
//  - Receive View operations and call external tools through Runner
//  - All cross-actor logic uses async / await + @MainActor, no longer using DispatchQueue
//

import AppKit
import Combine
import CoreLocation
import MapKit
import MachO

@MainActor
class LocationController: NSObject, ObservableObject, MKMapViewDelegate, CLLocationManagerDelegate, MKLocalSearchCompleterDelegate, ErrorHandlerHost {

    // MARK: - Enums

    enum DeviceMode: Int, Identifiable {
        case simulator
        case device
        var id: Int { rawValue }
    }

    enum PointsMode: Int, Identifiable {
        case single
        case two
        var id: Int { rawValue }
    }

    // MARK: - Public

    var alertText: String = ""

    // MARK: - Publishers

    // Feature switches
    @Published var showAndroidOption: Bool = false
    @Published var showSimulatorOption: Bool = false

    /// Simulation status (replaces the scattered isSimulating + simulationType strings)
    @Published var simulationStatus: SimulationStatus = .idle

    /// Reserved for SwiftUI backward compatibility: whether simulation is active (including Route, A->B, Single Point)
    var isSimulating: Bool { simulationStatus.isMockingActive }

    /// Compatibility field for LocationSettingsPanel
    var simulationType: SimulationStatus { simulationStatus }

    @Published var speed: Double = 15.0 {
        didSet { handleSpeedChange(oldValue: oldValue) }
    }
    @Published var pointsMode: PointsMode = .single {
        didSet { handlePointsModeChange() }
    }
    @Published var deviceMode: DeviceMode = .device
    @Published var xcodePath: String = "/Applications/Xcode.app" {
        didSet { defaults.set(xcodePath, forKey: Constants.defaultsXcodePathKey) }
    }

    /// Whether to use iOS 17+ RSD tunnel
    @Published var useRSD: Bool = true

    @Published var bootedSimulators: [Simulator] = []
    @Published var selectedSimulator: String = ""

    @Published var connectedDevices: [Device] = []
    @Published var selectedDevice: String = "" {
        didSet {
            // Automatically determine whether to use RSD based on iOS version
            if let device = connectedDevices.first(where: { $0.id == selectedDevice }),
               let major = device.version.components(separatedBy: ".").first,
               let v = Int(major) {
                useRSD = v >= 17
                AppLogger.shared.info("Selected device iOS version: \(device.version), auto useRSD=\(useRSD)")
            }
        }
    }

    @Published var showingAlert: Bool = false
    @Published var isShowingDialog: Bool = false
    @Published var deviceType: Int = 0
    @Published var adbPath: String = ""
    @Published var adbDeviceId: String = ""
    @Published var isEmulator: Bool = false

    /// Device connection status (replaces original isDeviceActive + tunnelStatus strings)
    @Published var deviceStatus: DeviceStatus = .idle {
        didSet { handleDeviceStatusChange(oldValue: oldValue) }
    }

    /// Compatibility fields: Existing UI dependency on isDeviceActive / tunnelStatus
    var isDeviceActive: Bool { deviceStatus.isActive }
    var tunnelStatus: String { deviceStatus.displayText }

    /// Whether location commands can be sent
    var isDeviceReady: Bool {
        if deviceType == 0 && deviceMode == .device {
            return deviceStatus.isReady
        }
        return true
    }

    @Published var timeScale: Double = 1.5 {
        didSet { runner.timeDelay = timeScale }
    }

    /// Logs for UI display (also written to file)
    @Published var logs: [LogEntry] = []

    @Published var searchQuery: String = "" {
        didSet {
            fullSearchResults = []
            completer.queryFragment = searchQuery
        }
    }
    @Published var searchResults: [MKLocalSearchCompletion] = []
    @Published var fullSearchResults: [MKMapItem] = []

    let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    @Published var savedLocations: [Location] = []
    @Published var locationLabels: [LocationLabel] = []

    /// Width (px) of the side panel currently covering the right edge of the
    /// map. Set by ContentView so that fly-to operations can offset the visible
    /// center, keeping the focused point in the un-covered area.
    @Published var mapVisibleInsetRight: CGFloat = 0

    // MARK: - Private

    private let mapView: MapView
    private let runner = Runner()
    private let client = MobileDeviceClient()
    private lazy var recovery = TunnelRecoveryCoordinator(client: client)
    private lazy var gpxPlayback: GPXPlayback = {
        let playback = GPXPlayback(client: client)
        playback.onUnexpectedExit = { [weak self] exitCode in
            Task { @MainActor in
                await self?.handleGPXPlaybackUnexpectedExit(exitCode: exitCode)
            }
        }
        return playback
    }()
    private let currentSimulationAnnotation = MKPointAnnotation()
    private let locationManager = CLLocationManager()
    private let completer = MKLocalSearchCompleter()
    private let defaults: UserDefaults = UserDefaults.standard
    private let logger = AppLogger.shared
    private lazy var errorHandler: ErrorHandler = ErrorHandler(host: self)

    private var isMapCentered = false

    private var annotations: [MKAnnotation] = []
    private var route: MKRoute?

    private var tracks: [Track] = []
    private var currentTrackIndex: Int = 0
    private var lastTrackLocation: CLLocationCoordinate2D?
    private var tracksTimes: [Track: Double] = [:]

    /// Full polyline, written by simulateRoute / simulateFromAToB;
    /// Used to regenerate GPX when speed dynamically changes.
    private var currentPolyline: [CLLocationCoordinate2D] = []
    /// Prevents continuous reschedule when speed changes, minimum interval 0.4s
    private var pendingSpeedRegenTask: Task<Void, Never>?
    /// Consecutive automatic GPX restarts after unexpected play-process exits.
    /// Capped so an unrecoverable device can't spin restart/alert loops.
    private var gpxRestartCount = 0
    private var lastGPXStartTime: Date = .distantPast
    /// GPX rendering runs detached (it can take seconds for long low-speed
    /// routes); this counter lets a stale render that finishes late detect it
    /// was superseded and skip starting playback with an outdated polyline.
    private var gpxKickoffGeneration = 0

    private var timer: Timer?
    private var lastRunnerUpdateTime: Date = .distantPast
    private var currentRunTask: Task<Void, Never>?

    // Joystick properties
    private var joystickDebounceTimer: Timer?
    private var joystickMovementTimer: Timer?
    private var activeKeys: Set<UInt16> = []

    // Health check (iOS physical device only)
    private var healthCheckTimer: Timer?
    private var healthCheckFailureStreak: Int = 0
    private static let healthCheckInterval: TimeInterval = 30.0
    private static let healthCheckFailureThreshold = 2

    // MARK: - Init

    init(mapView: MapView) {
        self.mapView = mapView
        super.init()

        completer.delegate = self
        if #available(macOS 15.0, *) {
            completer.resultTypes = [.address, .pointOfInterest, .physicalFeature]
        } else {
            completer.resultTypes = [.address, .pointOfInterest]
        }

        // Let Logger push each log back to UI (keep latest 500 entries)
        logger.addObserver { [weak self] entry in
            // This callback is already on main queue
            guard let self else { return }
            self.logs.insert(entry, at: 0)
            if self.logs.count > 500 {
                self.logs.removeLast(self.logs.count - 500)
            }
        }
        logger.info("App started, log path: \(logger.displayLogPath)")

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.startUpdatingLocation()
        locationManager.requestLocation()

        mapView.mkMapView.delegate = self
        mapView.viewHolder.clickAction = handleMapClick

        Task { @MainActor in
            await refreshDevices()

            deviceType = defaults.integer(forKey: "device_type")
            adbPath = defaults.string(forKey: "adb_path") ?? ""
            adbDeviceId = defaults.string(forKey: "adb_device_id") ?? ""
            isEmulator = defaults.bool(forKey: "is_emulator")
            xcodePath = defaults.string(forKey: Constants.defaultsXcodePathKey) ?? "/Applications/Xcode.app"

            loadLocations()
        }
    }

    // MARK: - Public

    func refreshDevices() async {
        if showSimulatorOption {
            bootedSimulators = (try? await getBootedSimulators()) ?? []
            selectedSimulator = bootedSimulators.first?.id ?? ""
        } else {
            bootedSimulators = []
            selectedSimulator = ""
        }

        connectedDevices = (try? await getConnectedDevices()) ?? []
        selectedDevice = connectedDevices.first?.id ?? ""
    }

    func setCurrentLocation() {
        guard let coord = locationManager.location?.coordinate else {
            showAlert("Unable to get Mac location")
            return
        }
        addLocation(coordinate: coord)
        flyToIfPointA(coord)
    }

    func setSelectedLocation() {
        if isRouteSimulationActive {
            logger.debug("Ignoring setSelectedLocation: route simulation is active")
            return
        }
        guard let annotation = annotations.first else {
            showAlert("Point A not selected")
            return
        }
        centerVisibleOn(annotation.coordinate)
        run(location: annotation.coordinate)
    }

    // MARK: Route

    func makeRoute(autoSimulate: Bool = false) {
        guard annotations.count == 2 else {
            showAlert("Route simulation requires two points")
            return
        }

        let startPoint = annotations[0].coordinate
        let endPoint = annotations[1].coordinate

        let sourcePlacemark = MKPlacemark(coordinate: startPoint, addressDictionary: nil)
        let destinationPlacemark = MKPlacemark(coordinate: endPoint, addressDictionary: nil)
        let sourceAnnotation = MKPointAnnotation()
        sourceAnnotation.coordinate = sourcePlacemark.coordinate
        let destinationAnnotation = MKPointAnnotation()
        destinationAnnotation.coordinate = destinationPlacemark.coordinate

        mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
        mapView.mkMapView.showAnnotations([sourceAnnotation, destinationAnnotation], animated: true)

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: sourcePlacemark)
        request.destination = MKMapItem(placemark: destinationPlacemark)
        request.transportType = .automobile

        let directions = MKDirections(request: request)
        directions.calculate { [weak self] response, error in
            guard let self else { return }
            // MKDirections completion callback might not be on the main thread, switch to main thread
            Task { @MainActor in
                guard let response else {
                    if let error { self.showAlert(error.localizedDescription) }
                    return
                }
                let route = response.routes[0]
                if let cur = self.route {
                    self.mapView.mkMapView.removeOverlay(cur.polyline)
                }
                self.route = route
                self.tracks = []
                self.mapView.mkMapView.addOverlay(route.polyline, level: .aboveRoads)

                let rect = route.polyline.boundingMapRect.insetBy(dx: -1000, dy: -1000)
                self.showVisibleMapRect(rect)

                if autoSimulate { self.simulateRoute() }
            }
        }
    }

    func simulateRoute() {
        guard let route else {
            showAlert("Route not yet created")
            return
        }

        let buffer = UnsafeBufferPointer(start: route.polyline.points(), count: route.polyline.pointCount)
        tracks = []
        var polyline: [CLLocationCoordinate2D] = []
        for i in 0..<route.polyline.pointCount {
            polyline.append(buffer[i].coordinate)
            if i + 1 < route.polyline.pointCount {
                tracks.append(Track(startPoint: buffer[i], endPoint: buffer[i + 1]))
            }
        }
        logger.debug("Total route segments: \(tracks.count)")

        invalidateState()
        currentPolyline = polyline
        simulationStatus = .route
        startMovementTimer()
        kickoffGPXPlaybackIfNeeded()
    }

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

            let rect = polyline.boundingMapRect.insetBy(dx: -1000, dy: -1000)
            showVisibleMapRect(rect)

            startMovementTimer()
            kickoffGPXPlaybackIfNeeded()
        }
    }

    private func startMovementTimer() {
        let interval = 0.1
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            // Timer callback is not necessarily on MainActor, redirecting to main thread
            Task { @MainActor in
                self.performMovement(stepScale: interval)
            }
        }
    }

    func updateMapRegion(force: Bool = false) {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
            return
        }
        guard !isMapCentered || force, let location = locationManager.location else {
            locationManager.requestAlwaysAuthorization()
            return
        }
        isMapCentered = true
        mapView.mkMapView.showsUserLocation = true
        centerVisibleOn(location.coordinate)
    }

    // MARK: Android

    func prepareEmulator() {
        guard ensureAdbAvailable() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.executeAdbCommand(args: ["shell", "settings", "put", "secure", "location_providers_allowed", "+gps"])
            await self.executeAdbCommand(
                args: ["shell", "settings", "put", "secure", "location_providers_allowed", "+network"],
                successMessage: "Emulator is ready"
            )
        }
    }

    func installHelperApp() {
        guard ensureAdbAvailable() else { return }
        guard let apkPath = Bundle.main.url(forResource: "helper-app", withExtension: "apk")?.path else {
            showAlert("helper-app.apk is missing from the app bundle")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.executeAdbCommand(
                args: ["-s", self.adbDeviceId, "install", apkPath],
                successMessage: "Helper App installation complete, please open and authorize on your phone"
            )
        }
    }

    private func ensureAdbAvailable() -> Bool {
        if adbDeviceId.isEmpty { showAlert("Android device ID"); return false }
        if adbPath.isEmpty { showAlert("adb path"); return false }
        return true
    }

    // MARK: Simulation control

    /// Cancel all Swift-level tasks and stop the GPX process handle.
    /// Does NOT pkill — callers must call client.killResidualSimulationProcesses()
    /// AFTER clearLocation so the broad "simulate-location" pattern doesn't
    /// match and kill the in-flight clear command.
    private func killAllActiveProcesses() async {
        pendingSpeedRegenTask?.cancel()
        pendingSpeedRegenTask = nil
        timer?.invalidate()
        timer = nil
        await gpxPlayback.stop()
        currentRunTask?.cancel()
        currentRunTask = nil
    }

    func stopSimulation(clearAnnotations: Bool = true) async {
        // Idempotent: a second call while already stopping is a no-op.
        guard simulationStatus.isMockingActive else { return }
        simulationStatus = .stopping
        let stopStarted = Date()

        await killAllActiveProcesses()

        if let transport = currentTransport() {
            do {
                try await client.clearLocation(transport: transport)
            } catch let error where (error as? AppError)?.isTunnelDrop == true {
                // Best-effort: the tunnel is already gone, nothing to clear.
                logger.warn("clearLocation skipped: tunnel unavailable")
            } catch {
                errorHandler.handle(error)
            }
        }
        await client.killResidualSimulationProcesses()

        mapView.mkMapView.removeOverlays(mapView.mkMapView.overlays)
        route = nil
        tracks = []
        currentPolyline = []

        if clearAnnotations {
            mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
            annotations = []
        }
        logger.info(String(format: "Simulation stopped (%.2fs)", Date().timeIntervalSince(stopStarted)))
        simulationStatus = .idle
    }

    /// Freezes route playback at the puck's current position. Tracks,
    /// currentTrackIndex, lastTrackLocation, currentPolyline, route overlay,
    /// and the puck annotation are preserved so resume can pick up in place.
    func pauseRouteSimulation() async {
        let paused: SimulationStatus
        switch simulationStatus {
        case .route:    paused = .routePaused
        case .fromAToB: paused = .fromAToBPaused
        default:        return
        }
        pendingSpeedRegenTask?.cancel()
        pendingSpeedRegenTask = nil
        timer?.invalidate()
        timer = nil
        await gpxPlayback.stop()
        simulationStatus = paused
        let holdCoord = lastTrackLocation ?? currentSimulationAnnotation.coordinate
        if CLLocationCoordinate2DIsValid(holdCoord) {
            run(location: holdCoord)
            lastRunnerUpdateTime = Date()
        }
        logger.info("Route simulation paused")
    }

    /// Resumes playback from the puck's current position. Restarts the local
    /// movement timer, and on the GPX path regenerates the GPX from the
    /// remaining polyline so pymobiledevice3 picks up where it left off.
    func resumeRouteSimulation() {
        let resumed: SimulationStatus
        switch simulationStatus {
        case .routePaused:    resumed = .route
        case .fromAToBPaused: resumed = .fromAToB
        default:              return
        }
        simulationStatus = resumed
        lastRunnerUpdateTime = .distantPast
        startMovementTimer()
        if shouldUseGPXPlayback, let endpoint = currentGPXEndpoint() {
            let remaining = remainingPolyline()
            if remaining.count >= 2 {
                startGPXPlayback(polyline: remaining, endpoint: endpoint, reason: "resume")
            }
        }
        logger.info("Route simulation resumed")
    }

    // MARK: Search

    func selectSearchCompletion(_ completion: MKLocalSearchCompletion) {
        let searchRequest = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: searchRequest)
        search.start { [weak self] response, _ in
            guard let self,
                  let coord = response?.mapItems.first?.placemark.coordinate else { return }
            Task { @MainActor in
                self.searchQuery = ""
                self.searchResults = []
                self.fullSearchResults = []
                self.putLocationOnMap(location: .init(name: completion.title,
                                                      latitude: coord.latitude,
                                                      longitude: coord.longitude))
                self.centerVisibleOn(coord)
            }
        }
    }

    func performFullSearch() {
        guard !searchQuery.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchQuery
        request.region = mapView.mkMapView.region

        MKLocalSearch(request: request).start { [weak self] response, error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    self.showAlert("Search failed: \(error.localizedDescription)")
                    return
                }
                self.searchResults = []
                self.fullSearchResults = response?.mapItems ?? []
            }
        }
    }

    func selectMapItem(_ item: MKMapItem) {
        let coord = item.placemark.coordinate
        searchQuery = ""
        fullSearchResults = []
        searchResults = []
        let name = item.name ?? item.placemark.title ?? "Unknown"
        putLocationOnMap(location: .init(name: name, latitude: coord.latitude, longitude: coord.longitude))
        centerVisibleOn(coord)
    }

    // MARK: - MKLocalSearchCompleterDelegate

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in
            self.searchResults = results
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        AppLogger.shared.warn("Search auto-completion failed: \(error.localizedDescription)")
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        let renderer = MKPolylineRenderer(overlay: overlay)
        renderer.strokeColor = NSColor(red: 17.0/255.0, green: 147.0/255.0, blue: 255.0/255.0, alpha: 1.0)
        renderer.lineWidth = 5.0
        return renderer
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        // Only handle the "currently simulating" orange puck style
        return dequeuePuckView(for: annotation, identifier: "simulationPuck")
    }

    private func dequeuePuckView(for annotation: MKAnnotation, identifier: String) -> MKAnnotationView? {
        guard annotation === currentSimulationAnnotation else { return nil }
        let map = mapView.mkMapView
        var view = map.dequeueReusableAnnotationView(withIdentifier: identifier)
        if view == nil {
            view = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view?.canShowCallout = false
            let size: CGFloat = 16
            let puck = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            puck.wantsLayer = true
            puck.layer?.cornerRadius = size / 2
            puck.layer?.backgroundColor = NSColor.orange.cgColor
            puck.layer?.borderWidth = 3
            puck.layer?.borderColor = NSColor.white.cgColor
            puck.layer?.shadowColor = NSColor.black.cgColor
            puck.layer?.shadowOpacity = 0.3
            puck.layer?.shadowOffset = CGSize(width: 0, height: 2)
            puck.layer?.shadowRadius = 3
            view?.addSubview(puck)
            view?.frame = puck.frame
            view?.centerOffset = .zero
        } else {
            view?.annotation = annotation
        }
        return view
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.updateMapRegion() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.updateMapRegion() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        AppLogger.shared.warn("CoreLocation error: \(error.localizedDescription)")
    }

    // MARK: - Device lifecycle

    func startDevice() {
        guard !selectedDevice.isEmpty else {
            showAlert("Device not selected")
            return
        }
        Task { @MainActor in
            logger.info("Starting device connection: \(selectedDevice), useRSD=\(useRSD)")
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
                await connectViaTunneld()
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

    private func connectViaTunneld() async {
        do {
            self.deviceStatus = .waitingAuthorization
            try await client.ensureTunneldRunning(allowLaunch: true)
            self.deviceStatus = .connected
            let udid = selectedDevice
            if !udid.isEmpty {
                Task { [weak self] in
                    guard let self else { return }
                    await self.client.warmUpLocationHelper(udid: udid)
                    // The user may have disconnected (or switched devices)
                    // while the warm-up was connecting — don't leave an
                    // orphaned helper bound to a dead tunnel.
                    if !self.deviceStatus.isReady || self.selectedDevice != udid {
                        self.logger.info("Device disconnected during helper warm-up; shutting helper down")
                        await self.client.shutdownLocationHelper()
                    }
                }
            }
        } catch {
            self.deviceStatus = .idle
            errorHandler.handle(error)
        }
    }

    func stopDevice() async {
        if useRSD {
            await stopRSDTunnel()
        } else {
            await stopLegacyDevice()
        }
    }

    private func stopLegacyDevice() async {
        logger.info("Stopping device (legacy)")
        await killAllActiveProcesses()
        simulationStatus = .idle
        if !selectedDevice.isEmpty {
            do {
                try await client.clearLocation(transport: .legacy(udid: selectedDevice))
            } catch let error where (error as? AppError)?.isTunnelDrop == true {
                // Best-effort: the tunnel is already gone, nothing to clear.
                logger.warn("clearLocation skipped: tunnel unavailable")
            } catch {
                errorHandler.handle(error)
            }
        }
        await client.killResidualSimulationProcesses()

        mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
        annotations = []
        if let route { mapView.mkMapView.removeOverlay(route.polyline) }
        deviceStatus = .idle
    }

    func stopRSDTunnel() async {
        logger.info("Stopping device (RSD)")
        await killAllActiveProcesses()
        simulationStatus = .idle
        if !selectedDevice.isEmpty {
            do {
                try await client.clearLocation(transport: .rsd(udid: selectedDevice))
            } catch let error where (error as? AppError)?.isTunnelDrop == true {
                // Best-effort: the tunnel is already gone, nothing to clear.
                logger.warn("clearLocation skipped: tunnel unavailable")
            } catch {
                errorHandler.handle(error)
            }
        }
        await client.shutdownLocationHelper()
        await client.killResidualSimulationProcesses()

        mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
        annotations = []
        if let route { mapView.mkMapView.removeOverlay(route.polyline) }
        deviceStatus = .idle
        // tunneld stays alive across app launches.
    }



    // MARK: - Saved locations

    func savePointA() {
        guard let p = annotations.first?.coordinate else {
            showAlert("Point A not selected")
            return
        }

        savedLocations.append(Location(
            name: "Point A (\(p.latitude) - \(p.longitude))",
            latitude: p.latitude,
            longitude: p.longitude
        ))
        saveSavedLocations()
    }

    func addSavedLocation(name: String, latLng: String) {
        let parts = latLng.components(separatedBy: ",")
        guard parts.count == 2,
              let lat = Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              let lng = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
              lat >= -90, lat <= 90, lng >= -180, lng <= 180 else {
            showAlert("Invalid coordinates — use format: lat, lng")
            return
        }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = label.isEmpty
            ? String(format: "%.5f, %.5f", lat, lng)
            : label
        savedLocations.append(Location(name: finalName, latitude: lat, longitude: lng))
        saveSavedLocations()
    }

    func removeLocation(location: Location) {
        savedLocations.removeAll { $0.id == location.id }
        saveSavedLocations()
    }

    func update(_ location: Location, with name: String) {
        guard let i = savedLocations.firstIndex(where: { $0.id == location.id }) else { return }
        let existing = savedLocations[i]
        var renamed = Location(
            name: name,
            latitude: existing.latitude,
            longitude: existing.longitude,
            labelIDs: existing.labelIDs
        )
        renamed.id = existing.id
        savedLocations[i] = renamed
        saveSavedLocations()
    }

    func putLocationOnMap(location: Location) {
        let coord = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        addLocation(coordinate: coord)
        flyToIfPointA(coord)
    }

    private func flyToIfPointA(_ coord: CLLocationCoordinate2D) {
        guard annotations.count == 1 else { return }
        centerVisibleOn(coord)
    }

    func applySavedLocation(_ location: Location) {
        let coord = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        addLocation(coordinate: coord)
        centerVisibleOn(coord)
    }

    // MARK: - Location labels

    @discardableResult
    func addLocationLabel(name: String) -> LocationLabel? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !locationLabels.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            showAlert("Label \"\(trimmed)\" already exists")
            return nil
        }
        let label = LocationLabel(name: trimmed)
        locationLabels.append(label)
        saveLocationLabels()
        return label
    }

    func renameLocationLabel(_ label: LocationLabel, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let i = locationLabels.firstIndex(where: { $0.id == label.id }) else { return }
        if locationLabels.contains(where: { $0.id != label.id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            showAlert("Label \"\(trimmed)\" already exists")
            return
        }
        locationLabels[i].name = trimmed
        saveLocationLabels()
    }

    /// Deletes a label and strips its ID from every saved location.
    func removeLocationLabel(_ label: LocationLabel) {
        locationLabels.removeAll { $0.id == label.id }
        var changed = false
        for i in savedLocations.indices where savedLocations[i].labelIDs.contains(label.id) {
            savedLocations[i].labelIDs.removeAll { $0 == label.id }
            changed = true
        }
        saveLocationLabels()
        if changed { saveSavedLocations() }
    }

    func toggleLabel(_ label: LocationLabel, on location: Location) {
        guard let i = savedLocations.firstIndex(where: { $0.id == location.id }) else { return }
        if savedLocations[i].labelIDs.contains(label.id) {
            savedLocations[i].labelIDs.removeAll { $0 == label.id }
        } else {
            savedLocations[i].labelIDs.append(label.id)
        }
        saveSavedLocations()
    }

    // MARK: - Visible-area map centering
    //
    // All fly-to / fit-to-rect calls funnel through these two helpers so the
    // side-panel offset is honored consistently. There are exactly three
    // user-facing operations that move the map programmatically:
    //
    //   1. Point A placement / re-apply  → centerVisibleOn(coord)
    //   2. Simulate Route (MKDirections) → showVisibleMapRect(route bounds)
    //   3. A → B Linear                  → showVisibleMapRect(line bounds)
    //
    // The same helpers also serve `updateMapRegion` (locate-me button) and
    // search-result picks. When the side panel is hidden,
    // `mapVisibleInsetRight` is 0 and the helpers degrade to a plain fit.

    /// Recenters the map on a single coordinate, keeping it inside the area
    /// NOT covered by the side panel.
    private func centerVisibleOn(
        _ coord: CLLocationCoordinate2D,
        latitudinalMeters: CLLocationDistance = 1000,
        longitudinalMeters: CLLocationDistance = 1000
    ) {
        let region = MKCoordinateRegion(
            center: coord,
            latitudinalMeters: latitudinalMeters,
            longitudinalMeters: longitudinalMeters
        )
        showVisibleMapRect(mapRect(for: region), edgeMargin: 20)
    }

    /// Fits an arbitrary `MKMapRect` (route bounds, A→B line, etc.) into the
    /// un-covered portion of the map.
    private func showVisibleMapRect(_ rect: MKMapRect, edgeMargin: CGFloat = 40) {
        let insets = NSEdgeInsets(
            top: edgeMargin,
            left: edgeMargin,
            bottom: edgeMargin,
            right: max(mapVisibleInsetRight, edgeMargin)
        )
        mapView.mkMapView.setVisibleMapRect(rect, edgePadding: insets, animated: true)
    }

    /// Converts an `MKCoordinateRegion` (center + span) into the equivalent
    /// `MKMapRect`, used as the input for `setVisibleMapRect(_:edgePadding:_:)`.
    private func mapRect(for region: MKCoordinateRegion) -> MKMapRect {
        let topLeft = CLLocationCoordinate2D(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude - region.span.longitudeDelta / 2
        )
        let bottomRight = CLLocationCoordinate2D(
            latitude: region.center.latitude - region.span.latitudeDelta / 2,
            longitude: region.center.longitude + region.span.longitudeDelta / 2
        )
        let p1 = MKMapPoint(topLeft)
        let p2 = MKMapPoint(bottomRight)
        return MKMapRect(
            x: min(p1.x, p2.x),
            y: min(p1.y, p2.y),
            width: abs(p1.x - p2.x),
            height: abs(p1.y - p2.y)
        )
    }

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

    func importLocations(from data: Data) {
        let locations = (try? JSONDecoder().decode([Location].self, from: data)) ?? []
        savedLocations.append(contentsOf: locations)
        saveSavedLocations()
    }

    func setToCoordinate(latString: String = "", lngString: String = "") {
        if isRouteSimulationActive {
            logger.debug("Ignoring setToCoordinate: route simulation is active")
            return
        }
        guard let lat = Double(latString), let lng = Double(lngString) else {
            showAlert("Coordinate format error")
            return
        }
        guard lat >= -90, lat <= 90, lng >= -180, lng <= 180 else {
            showAlert("Coordinate out of range (latitude -90~90, longitude -180~180)")
            return
        }
        putLocationOnMap(location: .init(name: "", latitude: lat, longitude: lng))
    }

    func setToCoordinate(latLngString: String = "") {
        let parts = latLngString.components(separatedBy: ",")
        guard parts.count == 2 else {
            showAlert("Coordinate format error")
            return
        }
        setToCoordinate(
            latString: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
            lngString: parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Private

    private func loadLocations() {
        if let data = defaults.data(forKey: Constants.defaultsSavedLocationsPathKey) {
            savedLocations = (try? JSONDecoder().decode([Location].self, from: data)) ?? []
        }
        if let data = defaults.data(forKey: Constants.defaultsLocationLabelsKey) {
            locationLabels = (try? JSONDecoder().decode([LocationLabel].self, from: data)) ?? []
        }
    }

    private func saveSavedLocations() {
        if let data = try? JSONEncoder().encode(savedLocations) {
            defaults.set(data, forKey: Constants.defaultsSavedLocationsPathKey)
        }
    }

    // MARK: - Device health check

    /// Reacts to deviceStatus transitions: start the liveness probe when the
    /// device becomes ready, stop it when it leaves ready (manual disconnect,
    /// error, or our own disconnect handler).
    private func handleDeviceStatusChange(oldValue: DeviceStatus) {
        if deviceStatus.isReady && !oldValue.isReady {
            startHealthCheckTimer()
        } else if !deviceStatus.isReady && oldValue.isReady {
            stopHealthCheckTimer()
        }
    }

    private func startHealthCheckTimer() {
        healthCheckTimer?.invalidate()
        healthCheckFailureStreak = 0
        logger.info("Device health check started (every \(Int(Self.healthCheckInterval))s)")
        healthCheckTimer = Timer.scheduledTimer(
            withTimeInterval: Self.healthCheckInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.performHealthCheck()
            }
        }
    }

    private func stopHealthCheckTimer() {
        guard healthCheckTimer != nil else { return }
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        healthCheckFailureStreak = 0
        logger.info("Device health check stopped")
    }

    private func performHealthCheck() async {
        guard deviceType == 0,
              deviceMode == .device,
              deviceStatus.isReady,
              !selectedDevice.isEmpty else {
            return
        }
        let snapshot = selectedDevice
        let devices: [Device]
        do {
            devices = try await client.listDevices()
        } catch {
            guard selectedDevice == snapshot, deviceStatus.isReady else { return }
            healthCheckFailureStreak += 1
            logger.warn("Health check listDevices failed (\(healthCheckFailureStreak)/\(Self.healthCheckFailureThreshold)): \(error.localizedDescription)")
            if healthCheckFailureStreak >= Self.healthCheckFailureThreshold {
                await attemptRecoveryOrDisconnect(udid: snapshot)
            }
            return
        }
        guard selectedDevice == snapshot, deviceStatus.isReady else { return }

        if devices.contains(where: { $0.id == snapshot }) {
            if useRSD {
                // USB presence isn't enough on the RSD path — usbmux answers
                // even when the tunnel is dead. Check the tunnel itself so
                // lock/sleep/tunneld-crash drops are caught here, not on the
                // user's next command.
                let tunnelAlive = await client.verifyTunnel(udid: snapshot)
                guard selectedDevice == snapshot, deviceStatus.isReady else { return }
                if tunnelAlive {
                    healthCheckFailureStreak = 0
                } else {
                    healthCheckFailureStreak += 1
                    logger.warn("Health check: tunnel for device missing (\(healthCheckFailureStreak)/\(Self.healthCheckFailureThreshold))")
                    if healthCheckFailureStreak >= Self.healthCheckFailureThreshold {
                        await attemptRecoveryOrDisconnect(udid: snapshot)
                    }
                }
            } else {
                healthCheckFailureStreak = 0
            }
        } else {
            healthCheckFailureStreak += 1
            logger.warn("Health check: device \(snapshot) missing (\(healthCheckFailureStreak)/\(Self.healthCheckFailureThreshold))")
            if healthCheckFailureStreak >= Self.healthCheckFailureThreshold {
                await attemptRecoveryOrDisconnect(udid: snapshot)
            }
        }
    }

    /// Tears down any active simulation, drops the device from the picker,
    /// resets status to idle, and alerts the user. Setting deviceStatus to
    /// .idle also triggers stopHealthCheckTimer via the didSet hook.
    /// Health-check entry point: try a silent tunnel recovery before tearing
    /// the device down. On success, reset the failure streak and (if a route
    /// was playing) restart GPX playback from the puck's current position,
    /// since the long-running `play` process dies when the tunnel drops.
    private func attemptRecoveryOrDisconnect(udid: String) async {
        if await attemptTunnelRecovery() {
            healthCheckFailureStreak = 0
            restartGPXPlaybackAfterRecoveryIfNeeded()
        } else {
            await handleDeviceDisconnection(udid: udid)
        }
    }

    /// Flips the device into `.reconnecting` and runs the recovery ladder.
    /// Returns true if the tunnel is live again. Only meaningful for the iOS
    /// physical-device RSD path; other modes can't lose a tunnel.
    private func attemptTunnelRecovery() async -> Bool {
        let udid = selectedDevice
        guard deviceType == 0, deviceMode == .device, useRSD, !udid.isEmpty else {
            return false
        }
        deviceStatus = .reconnecting
        let result = await recovery.recover(udid: udid)
        // The device may have been swapped out from under us while we awaited.
        guard selectedDevice == udid else { return result == .recovered }
        switch result {
        case .recovered:
            await client.shutdownLocationHelper()
            deviceStatus = .connected
            logger.info("Tunnel recovered for \(udid)")
            return true
        case .failed:
            return false
        }
    }

    /// Restarts GPX playback after a recovered tunnel, continuing from the
    /// current position rather than restarting the route from Point A.
    private func restartGPXPlaybackAfterRecoveryIfNeeded() {
        guard isRouteSimulationActive, !simulationStatus.isPaused, shouldUseGPXPlayback,
              let endpoint = currentGPXEndpoint() else { return }
        let remaining = remainingPolyline()
        guard remaining.count >= 2 else { return }
        startGPXPlayback(polyline: remaining, endpoint: endpoint, reason: "recovery")
    }

    /// Entry point for GPXPlayback.onUnexpectedExit: the play process died
    /// without our stop() — tunnel drop, pymobiledevice3 crash, or the process
    /// finishing the file slightly before the local puck. Recover the tunnel
    /// if needed and resume from the puck's current position.
    private func handleGPXPlaybackUnexpectedExit(exitCode: Int32) async {
        guard isRouteSimulationActive, !simulationStatus.isPaused, shouldUseGPXPlayback else { return }
        guard remainingPolyline().count >= 2 else {
            // Route is essentially finished; the local timer winds down normally.
            return
        }
        if Date().timeIntervalSince(lastGPXStartTime) > 30 { gpxRestartCount = 0 }
        guard gpxRestartCount < 3 else {
            logger.error("GPX playback died \(gpxRestartCount) times in a row — giving up")
            await handleDeviceDisconnection(udid: selectedDevice)
            return
        }
        gpxRestartCount += 1
        logger.warn("GPX playback exited unexpectedly (code \(exitCode)); restart attempt \(gpxRestartCount)/3")

        if useRSD {
            if await client.verifyTunnel(udid: selectedDevice) {
                // Tunnel is fine — the play process itself died. Just restart.
                restartGPXPlaybackAfterRecoveryIfNeeded()
            } else if await attemptTunnelRecovery() {
                restartGPXPlaybackAfterRecoveryIfNeeded()
            } else {
                await handleDeviceDisconnection(udid: selectedDevice)
            }
        } else {
            restartGPXPlaybackAfterRecoveryIfNeeded()
        }
    }

    private func handleDeviceDisconnection(udid: String) async {
        // Idempotent: inline and health-check paths may both reach here for the
        // same drop. Once we've reset to idle, don't tear down (and re-alert) again.
        guard deviceStatus != .idle else { return }
        logger.error("Device \(udid) disconnected — tunnel recovery failed")
        await client.shutdownLocationHelper()
        if simulationStatus.isMockingActive {
            await stopSimulation(clearAnnotations: true)
        } else {
            mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
            mapView.mkMapView.removeOverlays(mapView.mkMapView.overlays)
            annotations = []
            route = nil
        }
        connectedDevices.removeAll { $0.id == udid }
        selectedDevice = connectedDevices.first?.id ?? ""
        deviceStatus = .idle
        Task { @MainActor in
            await refreshDevices()
        }
        showAlert("iOS device disconnected. Check the USB cable or network connection, then reconnect.")
    }

    private func saveLocationLabels() {
        if let data = try? JSONEncoder().encode(locationLabels) {
            defaults.set(data, forKey: Constants.defaultsLocationLabelsKey)
        }
    }

    private func invalidateState() {
        timer?.invalidate()
        timer = nil
        lastTrackLocation = nil
        currentTrackIndex = 0
    }

    private func performMovement(stepScale: Double? = nil) {
        guard simulationStatus.isMockingActive,
              !tracks.isEmpty,
              currentTrackIndex < tracks.count else {
            Task { await stopSimulation(clearAnnotations: false) }
            printTimes()
            return
        }

        let scale = stepScale ?? 0.1
        let track = tracks[currentTrackIndex]
        let move = track.getNextLocation(from: lastTrackLocation, speed: (speed / 3.6) * scale)

        // In GPX mode, the pymobiledevice3 play process handles moving the device location;
        // The local timer only updates the orange puck on the map and no longer calls run(location:).
        let isGPXActive = shouldUseGPXPlayback

        switch move {
        case .moveTo(let to, _, _):
            lastTrackLocation = to
            if !isGPXActive,
               Date().timeIntervalSince(lastRunnerUpdateTime) >= timeScale {
                run(location: to)
                lastRunnerUpdateTime = Date()
            }
            currentSimulationAnnotation.coordinate = to

        case .finishTo(let to, _, _):
            lastTrackLocation = nil
            currentTrackIndex += 1
            if !isGPXActive {
                run(location: to)
                lastRunnerUpdateTime = Date()
            }
            currentSimulationAnnotation.coordinate = to
        }

        tracksTimes[track] = (tracksTimes[track] ?? 0) + scale

        // Ensure puck annotation is added to map
        if !mapView.mkMapView.annotations.contains(where: { $0 === currentSimulationAnnotation }) {
            mapView.mkMapView.addAnnotation(currentSimulationAnnotation)
        }
    }

    // MARK: - GPX Playback Orchestration

    /// Whether currently running (or paused while running) Route / A→B.
    /// Used to lock A/B annotations and gate the GPX speed-change handler.
    var isRouteSimulationActive: Bool {
        switch simulationStatus {
        case .route, .fromAToB, .routePaused, .fromAToBPaused: return true
        default: return false
        }
    }

    /// The transport to use for the currently selected device.
    /// Returns nil for non-iOS-device modes (Simulator / Android).
    private func currentTransport() -> MobileDeviceClient.Transport? {
        guard deviceType == 0, deviceMode == .device, !selectedDevice.isEmpty else { return nil }
        return useRSD ? .rsd(udid: selectedDevice) : .legacy(udid: selectedDevice)
    }

    /// Whether the current conditions allow for GPX path: iOS physical device + RSD/legacy both supported
    private var shouldUseGPXPlayback: Bool {
         deviceType == 0 && deviceMode == .device && isDeviceReady
    }

    /// Based on current useRSD setting, returns GPXPlayback.Endpoint
    private func currentGPXEndpoint() -> GPXPlayback.Endpoint? {
        guard !selectedDevice.isEmpty else { return nil }
        return useRSD ? .rsd(udid: selectedDevice) : .legacy(udid: selectedDevice)
    }

    /// Called at the start of simulateRoute / simulateFromAToB:
    /// If conditions match -> generates GPX and starts pymobiledevice3 play
    private func kickoffGPXPlaybackIfNeeded() {
        guard shouldUseGPXPlayback,
              let endpoint = currentGPXEndpoint(),
              currentPolyline.count >= 2 else { return }
        gpxRestartCount = 0
        startGPXPlayback(polyline: currentPolyline, endpoint: endpoint, reason: "initial")
    }

    /// Triggered when speed dynamically changes: restarts playback with a new GPX starting from the current puck position.
    /// Does not "restart from point A".
    private func handleSpeedChange(oldValue: Double) {
        guard isRouteSimulationActive, gpxPlayback.isPlaying else { return }
        guard abs(oldValue - speed) > 0.1 else { return }
        // Simple throttle: cancel the previous pending task and reschedule for 0.4s later to avoid excessive restarts while dragging the slider
        pendingSpeedRegenTask?.cancel()
        pendingSpeedRegenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.isRouteSimulationActive, self.gpxPlayback.isPlaying else { return }
            guard let endpoint = self.currentGPXEndpoint() else { return }
            let remaining = self.remainingPolyline()
            guard remaining.count >= 2 else { return }
            self.startGPXPlayback(polyline: remaining, endpoint: endpoint, reason: "speed=\(Int(self.speed))km/h")
        }
    }

    /// Shared: Write file + start GPXPlayback.
    /// Sampling + XML rendering can take seconds for long low-speed routes, so
    /// it runs detached; the generation guard drops a stale render that
    /// finishes after a newer kickoff (e.g. rapid speed-slider changes).
    private func startGPXPlayback(
        polyline: [CLLocationCoordinate2D],
        endpoint: GPXPlayback.Endpoint,
        reason: String
    ) {
        gpxKickoffGeneration += 1
        let generation = gpxKickoffGeneration
        let speedKmh = speed
        Task { @MainActor [weak self] in
            let name = "route-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))"
            let url: URL
            do {
                url = try await Task.detached(priority: .userInitiated) {
                    let rendered = try GPXGenerator.render(
                        polyline: polyline,
                        speedKmh: speedKmh,
                        name: name
                    )
                    GPXGenerator.pruneOldFiles()
                    return rendered
                }.value
            } catch {
                self?.logger.error("Failed to write GPX: \(error.localizedDescription)")
                self?.showAlert("Failed to write GPX: \(error.localizedDescription)")
                return
            }
            guard let self, generation == self.gpxKickoffGeneration else { return }
            self.logger.info("GPX written (\(reason)): \(url.path) – \(polyline.count) nodes @ \(Int(speedKmh)) km/h")

            let alert: (String) -> Void = { [weak self] msg in
                Task { @MainActor in self?.showAlert(msg) }
            }
            self.lastGPXStartTime = Date()
            await self.gpxPlayback.start(gpxURL: url, endpoint: endpoint, alert: alert)
        }
    }

    /// Calculates the remaining polyline from "current position -> route end".
    /// If lastTrackLocation is nil, it means just switched to the next track, using that track's start point.
    private func remainingPolyline() -> [CLLocationCoordinate2D] {
        guard !tracks.isEmpty, currentTrackIndex < tracks.count else { return [] }
        var pts: [CLLocationCoordinate2D] = []
        let track = tracks[currentTrackIndex]
        pts.append(lastTrackLocation ?? track.startPoint.coordinate)
        pts.append(track.endPoint.coordinate)
        for i in (currentTrackIndex + 1)..<tracks.count {
            pts.append(tracks[i].endPoint.coordinate)
        }
        return pts
    }

    private func executeAdbCommand(args: [String], successMessage: String? = nil) async {
        guard ensureAdbAvailable() else { return }
        do {
            // `adb install` of the bundled helper APK can take a while on a
            // slow device, hence the generous timeout.
            let result = try await ProcessRunner.execute(executable: adbPath, args: args, timeout: 120)
            let err = String(decoding: result.stderr, as: UTF8.self)
            if !err.isEmpty {
                showAlert(err)
            } else if let msg = successMessage {
                showAlert(msg)
            }
        } catch {
            showAlert(error.localizedDescription)
        }
    }

    private func printTimes() {
        tracksTimes.forEach { track, time in
            let distance = CLLocation.distance(from: track.startPoint.coordinate, to: track.endPoint.coordinate)
            let speed = distance / time
            logger.debug("Track result: speed=\(speed * 3.6) km/h, distance=\(distance)m, time=\(time)s")
        }
    }

    private func handlePointsModeChange() {
        // Whenever the user switches modes, terminate any simulation that
        // belongs to the previous mode so the new mode starts clean.
        // .mocking → single-point; .route/.fromAToB → two-point.
        let needsStop = simulationStatus.isMockingActive
        Task { @MainActor in
            if needsStop {
                await stopSimulation(clearAnnotations: false)
            }
            mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
            mapView.mkMapView.removeOverlays(mapView.mkMapView.overlays)
            annotations = []
            route = nil
        }
    }

    private func handleMapClick(_ sender: NSClickGestureRecognizer) {
        let point = sender.location(in: mapView.mkMapView)
        let coord = mapView.mkMapView.convert(point, toCoordinateFrom: mapView.mkMapView)
        addLocation(coordinate: coord)
    }

    private func addLocation(coordinate: CLLocationCoordinate2D) {
        // Lock points A and B during Route / A→B simulation: Stop must be pressed before changes can be made.
        if isRouteSimulationActive {
            logger.debug("Ignoring map click: route simulation is active, A/B locked")
            return
        }
        if pointsMode == .single {
            mapView.mkMapView.removeAnnotations(annotations)
            annotations = []
        }
        if annotations.count == 2 {
            mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
            annotations = []
            return
        }

        let annotation = MKPointAnnotation()
        annotation.coordinate = coordinate
        annotation.title = annotations.isEmpty ? "A" : "B"
        annotations.append(annotation)
        mapView.mkMapView.addAnnotation(annotation)
    }

    /// Send location command to the corresponding device
    private func run(location: CLLocationCoordinate2D) {
        // Persist user input
        defaults.set(deviceType, forKey: "device_type")
        defaults.set(adbPath, forKey: "adb_path")
        defaults.set(adbDeviceId, forKey: "adb_device_id")
        defaults.set(isEmulator, forKey: "is_emulator")

        currentRunTask?.cancel()
        // Flip UI to "mocking" immediately so the Apply→Stop toggle feels
        // instantaneous. The async device call below may take hundreds of ms.
        // On failure, the catch branches revert to .idle.
        if simulationStatus == .idle { simulationStatus = .mocking }
        let weakAlert: (String) -> Void = { [weak self] msg in
            Task { @MainActor in self?.showAlert(msg) }
        }

        // Android
        if deviceType != 0 {
            currentRunTask = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                guard self.ensureAdbAvailable() else {
                    if self.simulationStatus == .mocking { self.simulationStatus = .idle }
                    return
                }
                self.logger.debug("Android location: deviceId=\(self.adbDeviceId), isEmulator=\(self.isEmulator)")
                await self.runner.runOnAndroid(
                    location: location,
                    adbDeviceId: self.adbDeviceId,
                    adbPath: self.adbPath,
                    isEmulator: self.isEmulator,
                    showAlert: weakAlert
                )
            }
            return
        }

        // iOS Device
        if deviceMode == .device {
            if useRSD {
                currentRunTask = Task { [weak self] in
                    if Task.isCancelled { return }
                    guard let self else { return }
                    do {
                        try await self.client.setLocation(location, transport: .rsd(udid: self.selectedDevice))
                    } catch let e where (e as? AppError)?.isTunnelDrop == true {
                        // Tunnel dropped mid-send — try to recover silently and
                        // re-send this fix once, rather than aborting the user.
                        if await self.attemptTunnelRecovery() {
                            try? await self.client.setLocation(location, transport: .rsd(udid: self.selectedDevice))
                        } else {
                            if self.simulationStatus == .mocking { self.simulationStatus = .idle }
                            await self.handleDeviceDisconnection(udid: self.selectedDevice)
                        }
                    } catch {
                        if self.simulationStatus == .mocking { self.simulationStatus = .idle }
                        self.errorHandler.handle(error)
                    }
                }
            } else {
                currentRunTask = Task { [weak self] in
                    if Task.isCancelled { return }
                    guard let self else { return }
                    do {
                        try await self.client.setLocation(location, transport: .legacy(udid: self.selectedDevice))
                    } catch {
                        if self.simulationStatus == .mocking { self.simulationStatus = .idle }
                        self.errorHandler.handle(error)
                    }
                }
            }
            return
        }

        // iOS Simulator
        if bootedSimulators.isEmpty {
            simulationStatus = .idle
            showAlert(SimulatorFetchError.noBootedSimulators.description)
            return
        }
        currentRunTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.runner.runOnSimulator(
                location: location,
                selectedSimulator: self.selectedSimulator,
                bootedSimulators: self.bootedSimulators
            )
        }
    }

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
        }
    }

    func presentAlert(message: String) {
        alertText = message
        showingAlert = true
        simulationStatus = .idle
    }
}

// MARK: - Private: List iOS devices

private extension LocationController {

    func getConnectedDevices() async throws -> [Device] {
        return try await client.listDevices()
    }

    func getBootedSimulators() async throws -> [Simulator] {
        let result = try await ProcessRunner.execute(
            executable: "/usr/bin/xcrun",
            args: ["simctl", "list", "-j", "devices"],
            timeout: 30
        )

        if result.exitCode != 0 { throw SimulatorFetchError.simctlFailed }
        let booted: [Simulator]
        do {
            booted = try JSONDecoder().decode(Simulators.self, from: result.stdout).bootedSimulators
        } catch {
            throw SimulatorFetchError.failedToReadOutput
        }
        if booted.isEmpty { throw SimulatorFetchError.noBootedSimulators }

        logger.info("Booted simulators: \(booted.map { "\($0.name)" }.joined(separator: ", "))")
        return [Simulator.empty()] + booted
    }
}

// MARK: - Joystick

extension LocationController {

    func handleKeyEvent(_ event: NSEvent) {
        // Do not process during Dialog / Alert / text input / Route simulation
        guard pointsMode == .single, !showingAlert, !isShowingDialog, !isRouteSimulationActive else { return }
        if let fr = NSApp.keyWindow?.firstResponder, fr.isKind(of: NSTextView.self) { return }

        let isDown = event.type == .keyDown
        let key = event.keyCode

        // Up 126 Down 125 Left 123 Right 124
        if [123, 124, 125, 126].contains(key) {
            if isDown {
                activeKeys.insert(key)
                startJoystickMovement()
            } else {
                activeKeys.remove(key)
                if activeKeys.isEmpty {
                    scheduleJoystickDebounce()
                }
            }
        }
    }

    private func startJoystickMovement() {
        joystickDebounceTimer?.invalidate()
        joystickDebounceTimer = nil

        guard joystickMovementTimer == nil else { return }

        // Start point: Point A or current location
        let startCoord: CLLocationCoordinate2D
        if let first = annotations.first as? MKPointAnnotation {
            startCoord = first.coordinate
        } else if let loc = locationManager.location?.coordinate {
            startCoord = loc
        } else {
            return
        }

        // Hide Point A and show orange puck
        mapView.mkMapView.removeAnnotations(annotations)
        annotations = []
        currentSimulationAnnotation.coordinate = startCoord
        if !mapView.mkMapView.annotations.contains(where: { $0 === currentSimulationAnnotation }) {
            mapView.mkMapView.addAnnotation(currentSimulationAnnotation)
        }

        logger.debug("Joystick started, current simulation status: \(simulationStatus)")

        // 60fps update map
        joystickMovementTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateJoystickPosition() }
        }
    }

    private func scheduleJoystickDebounce() {
        joystickDebounceTimer?.invalidate()
        joystickDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.commitJoystickMovement() }
        }
    }

    private func commitJoystickMovement() {
        joystickMovementTimer?.invalidate()
        joystickMovementTimer = nil

        let finalCoord = currentSimulationAnnotation.coordinate
        mapView.mkMapView.removeAnnotation(currentSimulationAnnotation)
        addLocation(coordinate: finalCoord)

        // Rules of behavior:
        // - If location simulation is currently active (simulationStatus.isMockingActive) -> update location directly
        // - If currently not simulating -> only update map marker, do not send to device
        if simulationStatus.isMockingActive && isDeviceReady {
            run(location: finalCoord)
            lastRunnerUpdateTime = Date()
            logger.debug("Joystick commit: send location directly lat=\(finalCoord.latitude), lng=\(finalCoord.longitude)")
        } else {
            logger.debug("Joystick commit: not mocking, only update map")
        }
    }

    private func updateJoystickPosition() {
        let pixelsPerFrame: Double = 0.005
        var dx = 0.0, dy = 0.0
        if activeKeys.contains(126) { dy += pixelsPerFrame }
        if activeKeys.contains(125) { dy -= pixelsPerFrame }
        if activeKeys.contains(123) { dx -= pixelsPerFrame }
        if activeKeys.contains(124) { dx += pixelsPerFrame }
        if dx == 0 && dy == 0 { return }

        let span = mapView.mkMapView.region.span
        let coord = currentSimulationAnnotation.coordinate
        let newCoord = CLLocationCoordinate2D(
            latitude: coord.latitude + dy * span.latitudeDelta,
            longitude: coord.longitude + dx * span.longitudeDelta
        )
        currentSimulationAnnotation.coordinate = newCoord
        mapView.mkMapView.setCenter(newCoord, animated: false)

        // If simulating, update device location in real-time after throttle
        if simulationStatus.isMockingActive && isDeviceReady,
           Date().timeIntervalSince(lastRunnerUpdateTime) >= timeScale {
            run(location: newCoord)
            lastRunnerUpdateTime = Date()
        }
    }

    enum SimulatorFetchError: Error, CustomStringConvertible {
        case simctlFailed
        case failedToReadOutput
        case noBootedSimulators
        case noMatchingSimulators(name: String)
        case noMatchingUDID(udid: UUID)

        var description: String {
            switch self {
            case .simctlFailed:               return "Failed to execute simctl list"
            case .failedToReadOutput:         return "Unable to parse simctl output"
            case .noBootedSimulators:         return "No booted simulators found"
            case .noMatchingSimulators(let n):return "Could not find simulator named '\(n)'"
            case .noMatchingUDID(let u):      return "Could not find UDID: \(u.uuidString)"
            }
        }
    }
}

extension CLLocation {
    static func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
        let a = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let b = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return a.distance(from: b)
    }
}

private enum Constants {
    static let defaultsSavedLocationsPathKey = "saved_locations"
    static let defaultsLocationLabelsKey = "location_labels"
    static let defaultsXcodePathKey = "xcode_path"
    static let developerModeInstructions = """
    Developer Mode needs to be enabled:

    1. Open "Settings" on iPhone
    2. Go to "Privacy & Security"
    3. Scroll to the bottom and tap "Developer Mode"
    4. Turn on the switch and restart the device
    """
}
