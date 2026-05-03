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
class LocationController: NSObject, ObservableObject, MKMapViewDelegate, CLLocationManagerDelegate, MKLocalSearchCompleterDelegate {

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

    @Published var speed: Double = 60.0
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

    @Published var RSDAddress: String = ""
    @Published var RSDPort: String = ""

    /// Device connection status (replaces original isDeviceActive + tunnelStatus strings)
    @Published var deviceStatus: DeviceStatus = .idle

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

    // MARK: - Private

    private let mapView: MapView
    private let runner = Runner()
    private let currentSimulationAnnotation = MKPointAnnotation()
    private let locationManager = CLLocationManager()
    private let completer = MKLocalSearchCompleter()
    private let defaults: UserDefaults = UserDefaults.standard
    private let logger = AppLogger.shared

    private var isMapCentered = false

    private var annotations: [MKAnnotation] = []
    private var route: MKRoute?

    private var tracks: [Track] = []
    private var currentTrackIndex: Int = 0
    private var lastTrackLocation: CLLocationCoordinate2D?
    private var tracksTimes: [Track: Double] = [:]

    private var timer: Timer?
    private var lastRunnerUpdateTime: Date = .distantPast
    private var currentRunTask: Task<Void, Never>?

    // Joystick properties
    private var joystickDebounceTimer: Timer?
    private var joystickMovementTimer: Timer?
    private var activeKeys: Set<UInt16> = []

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
            bootedSimulators = (try? getBootedSimulators()) ?? []
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
    }

    func setSelectedLocation() {
        guard let annotation = annotations.first else {
            showAlert("Point A not selected")
            return
        }
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

                let rect = route.polyline.boundingMapRect
                self.mapView.mkMapView.setRegion(MKCoordinateRegion(rect.insetBy(dx: -1000, dy: -1000)), animated: true)

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
        for i in 0..<route.polyline.pointCount where i + 1 < route.polyline.pointCount {
            tracks.append(Track(startPoint: buffer[i], endPoint: buffer[i + 1]))
        }
        logger.debug("Total route segments: \(tracks.count)")

        invalidateState()
        simulationStatus = .route
        startMovementTimer()
    }

    func simulateFromAToB() {
        guard annotations.count == 2 else {
            showAlert("A->B simulation requires two points")
            return
        }
        let startPoint = annotations[0]
        let endPoint = annotations[1]
        stopSimulation(clearAnnotations: false)

        // Connect A and B with a straight line
        let polyline = MKPolyline(coordinates: [startPoint.coordinate, endPoint.coordinate], count: 2)
        mapView.mkMapView.addOverlay(polyline, level: .aboveRoads)

        tracks = [Track(startPoint: MKMapPoint(startPoint.coordinate), endPoint: MKMapPoint(endPoint.coordinate))]
        invalidateState()
        simulationStatus = .fromAToB
        startMovementTimer()
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
        let region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)
        mapView.mkMapView.setRegion(mapView.mkMapView.regionThatFits(region), animated: true)
    }

    // MARK: Android

    func prepareEmulator() {
        guard ensureAdbAvailable() else { return }
        executeAdbCommand(args: ["shell", "settings", "put", "secure", "location_providers_allowed", "+gps"])
        executeAdbCommand(
            args: ["shell", "settings", "put", "secure", "location_providers_allowed", "+network"],
            successMessage: "Emulator is ready"
        )
    }

    func installHelperApp() {
        guard ensureAdbAvailable() else { return }
        let apkPath = Bundle.main.url(forResource: "helper-app", withExtension: "apk")!.path
        executeAdbCommand(
            args: ["-s", adbDeviceId, "install", apkPath],
            successMessage: "Helper App installation complete, please open and authorize on your phone"
        )
    }

    private func ensureAdbAvailable() -> Bool {
        if adbDeviceId.isEmpty { showAlert("Android device ID"); return false }
        if adbPath.isEmpty { showAlert("adb path"); return false }
        return true
    }

    // MARK: Simulation control

    func stopSimulation(clearAnnotations: Bool = true) {
        simulationStatus = .idle
        Task { await runner.stopCurrentTask() }
        timer?.invalidate()
        timer = nil

        // Clear route and overlays
        mapView.mkMapView.removeOverlays(mapView.mkMapView.overlays)
        route = nil
        tracks = []

        if clearAnnotations {
            mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
            annotations = []
        }
        logger.info("Simulation stopped")
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
                let region = MKCoordinateRegion(center: coord, latitudinalMeters: 1000, longitudinalMeters: 1000)
                self.mapView.mkMapView.setRegion(region, animated: true)
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
        let region = MKCoordinateRegion(center: coord, latitudinalMeters: 1000, longitudinalMeters: 1000)
        mapView.mkMapView.setRegion(region, animated: true)
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

    func mountDeveloperImage() {
        guard let device = connectedDevices.first(where: { $0.id == selectedDevice }) else {
            showAlert("Device not selected")
            return
        }
        Task { @MainActor in
            self.deviceStatus = .mounting
            do {
                let mountTask = try await runner.taskForIOS(args: ["mounter", "auto-mount", "--udid", device.id])

                let outPipe = Pipe()
                let errPipe = Pipe()
                mountTask.standardOutput = outPipe
                mountTask.standardError = errPipe

                try mountTask.run()
                mountTask.waitUntilExit()

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                outPipe.fileHandleForReading.closeFile()

                var isAlreadyMounted = false
                if let errData = try? errPipe.fileHandleForReading.readToEnd(),
                   let text = String(data: errData, encoding: .utf8), !text.isEmpty {
                    if text.range(of: "already mounted", options: .caseInsensitive) != nil ||
                       text.range(of: "Image is already mounted", options: .caseInsensitive) != nil {
                        isAlreadyMounted = true
                        logger.info("Developer Image already mounted on device")
                    } else if text.contains("DeviceLocked") {
                        showAlert("Error: Device is locked")
                    } else {
                        showAlert(text)
                    }
                }
                if let text = String(data: outData, encoding: .utf8), !text.isEmpty {
                    logger.debug(text)
                }

                if mountTask.terminationStatus == 0 || isAlreadyMounted {
                    self.deviceStatus = .connected
                } else {
                    self.deviceStatus = .idle
                }
            } catch {
                self.deviceStatus = .idle
                showAlert(error.localizedDescription)
            }
        }
    }

    func startDevice() {
        guard !selectedDevice.isEmpty else {
            showAlert("Device not selected")
            return
        }
        Task { @MainActor in
            self.deviceStatus = .checkingDeveloperMode
            let isEnabled = await runner.checkDeveloperModeStatus(udid: selectedDevice)
            if !isEnabled {
                await runner.revealDeveloperMode(udid: selectedDevice)
                self.deviceStatus = .idle
                showAlert(Constants.developerModeInstructions)
                return
            }
            if useRSD {
                startRSDTunnel()
            } else {
                mountDeveloperImage()
            }
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
        simulationStatus = .idle
        await runner.stopCurrentTask()
        await runner.resetIos(
            udid: selectedDevice,
            useRSD: false,
            RSDAddress: "",
            RSDPort: "",
            showAlert: { [weak self] msg in self?.showAlert(msg) }
        )

        mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
        annotations = []
        if let route { mapView.mkMapView.removeOverlay(route.polyline) }
        deviceStatus = .idle
    }

    func startRSDTunnel() {
        let deviceId = selectedDevice
        guard !deviceId.isEmpty else {
            showAlert("Device not selected")
            return
        }
        guard let pymobilePath = runner.getFullPathOf("pymobiledevice3") else {
            showAlert("Could not find pymobiledevice3, please install it first")
            return
        }

        deviceStatus = .waitingAuthorization

        // Tunnel startup requires sudo authorization and must trigger a system prompt. Using background Task to execute AppleScript instead.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let logPath = "/tmp/sim_rsd_\(deviceId).log"
            try? "".write(toFile: logPath, atomically: true, encoding: .utf8)

            // Trigger system authorization dialog via AppleScript
            let scriptSource = "do shell script \"sh -c '\(pymobilePath) remote start-tunnel --udid \(deviceId) --protocol tcp > \(logPath) 2>&1 &'\" with administrator privileges"

            let script = NSAppleScript(source: scriptSource)
            var err: NSDictionary?
            script?.executeAndReturnError(&err)

            if let err {
                let msg = err[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                await MainActor.run {
                    AppLogger.shared.error("Authorization failed: \(msg)")
                    self.deviceStatus = .idle
                    if !msg.contains("User canceled") {
                        self.showAlert("Authorization failed: \(msg)")
                    }
                }
                return
            }

            await MainActor.run {
                self.deviceStatus = .connecting
                AppLogger.shared.info("Tunnel started in background, monitoring logs")
                self.monitorRSDLog(at: logPath)
            }
        }
    }

    private func monitorRSDLog(at path: String) {
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            attempts += 1
            // Timer callback switch to main thread
            Task { @MainActor in
                guard let self, self.deviceStatus.isActive else {
                    timer.invalidate()
                    return
                }
                if let content = try? String(contentsOfFile: path, encoding: .utf8), !content.isEmpty {
                    self.parseRSDOutput(content)
                    if case .connected = self.deviceStatus {
                        timer.invalidate()
                        return
                    }
                }
                if attempts >= 30 { // Approx. 45 seconds
                    timer.invalidate()
                    if case .connected = self.deviceStatus {} else {
                        self.showAlert("Connection timed out, please check device connection")
                        self.deviceStatus = .idle
                        self.killRSDTunnel(for: self.selectedDevice)
                    }
                }
            }
        }
    }

    func stopRSDTunnel() async {
        simulationStatus = .idle
        await runner.stopCurrentTask()
        logger.info("Stopping RSD tunnel")

        await runner.resetIos(
            udid: selectedDevice,
            useRSD: useRSD,
            RSDAddress: RSDAddress,
            RSDPort: RSDPort,
            showAlert: { [weak self] msg in self?.showAlert(msg) }
        )

        mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
        annotations = []
        if let route { mapView.mkMapView.removeOverlay(route.polyline) }
        deviceStatus = .idle
        killRSDTunnel(for: selectedDevice)
    }

    private func killRSDTunnel(for udid: String) {
        let script = "do shell script \"pkill -f 'pymobiledevice3.*\(udid)'\" with administrator privileges"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
        logger.info("Background tunnel processes cleared")
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

    func removeLocation(location: Location) {
        savedLocations.removeAll { $0.id == location.id }
        saveSavedLocations()
    }

    func update(_ location: Location, with name: String) {
        guard let i = savedLocations.firstIndex(where: { $0.id == location.id }) else { return }
        savedLocations.remove(at: i)
        savedLocations.insert(
            Location(name: name, latitude: location.latitude, longitude: location.longitude),
            at: i
        )
        saveSavedLocations()
    }

    func putLocationOnMap(location: Location) {
        addLocation(coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude))
    }

    func applySavedLocation(_ location: Location) {
        let coord = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        addLocation(coordinate: coord)
        let region = MKCoordinateRegion(center: coord, latitudinalMeters: 1000, longitudinalMeters: 1000)
        mapView.mkMapView.setRegion(region, animated: true)
    }

    func showAlert(_ text: String) {
        // Ensure already on the main thread (class is marked @MainActor)
        alertText = text
        showingAlert = true
        simulationStatus = .idle
        logger.warn("Alert: \(text)")
    }

    func importLocations(from data: Data) {
        let locations = (try? JSONDecoder().decode([Location].self, from: data)) ?? []
        savedLocations.append(contentsOf: locations)
        saveSavedLocations()
    }

    func setToCoordinate(latString: String = "", lngString: String = "") {
        guard let lat = Double(latString), let lng = Double(lngString) else {
            showAlert("Coordinate format error")
            return
        }
        guard lat >= -90, lat <= 90, lng >= -180, lng <= 180 else {
            showAlert("Coordinate out of range (latitude -90~90, longitude -180~180)")
            return
        }
        putLocationOnMap(location: .init(name: "", latitude: lat, longitude: lng))
        run(location: .init(latitude: lat, longitude: lng))
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

    private func parseRSDOutput(_ output: String) {
        if let r = output.range(of: "RSD Address:\\s*([a-fA-F0-9:]+)", options: .regularExpression) {
            let comps = output[r].components(separatedBy: CharacterSet.whitespaces)
            if comps.count >= 2, let addr = comps.last, !addr.isEmpty, addr != RSDAddress {
                RSDAddress = addr
            }
        }
        if let r = output.range(of: "RSD Port:\\s*(\\d+)", options: .regularExpression) {
            let comps = output[r].components(separatedBy: CharacterSet.whitespaces)
            if comps.count >= 2, let port = comps.last, !port.isEmpty, port != RSDPort {
                RSDPort = port
                deviceStatus = .connected
                showAlert("RSD tunnel connected!")
            }
        }
    }

    private func loadLocations() {
        guard let data = defaults.data(forKey: Constants.defaultsSavedLocationsPathKey) else { return }
        savedLocations = (try? JSONDecoder().decode([Location].self, from: data)) ?? []
    }

    private func saveSavedLocations() {
        if let data = try? JSONEncoder().encode(savedLocations) {
            defaults.set(data, forKey: Constants.defaultsSavedLocationsPathKey)
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
            stopSimulation(clearAnnotations: false)
            printTimes()
            return
        }

        let scale = stepScale ?? 0.1
        let track = tracks[currentTrackIndex]
        let move = track.getNextLocation(from: lastTrackLocation, speed: (speed / 3.6) * scale)

        switch move {
        case .moveTo(let to, _, _):
            lastTrackLocation = to
            // To avoid command flooding, send every timeScale seconds
            if Date().timeIntervalSince(lastRunnerUpdateTime) >= timeScale {
                run(location: to)
                lastRunnerUpdateTime = Date()
            }
            currentSimulationAnnotation.coordinate = to

        case .finishTo(let to, _, _):
            lastTrackLocation = nil
            currentTrackIndex += 1
            run(location: to)
            lastRunnerUpdateTime = Date()
            currentSimulationAnnotation.coordinate = to
        }

        tracksTimes[track] = (tracksTimes[track] ?? 0) + scale

        // Ensure puck annotation is added to map
        if !mapView.mkMapView.annotations.contains(where: { $0 === currentSimulationAnnotation }) {
            mapView.mkMapView.addAnnotation(currentSimulationAnnotation)
        }
    }

    private func executeAdbCommand(args: [String], successMessage: String? = nil) {
        guard ensureAdbAvailable() else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            showAlert(error.localizedDescription)
            return
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let err = String(decoding: errData, as: UTF8.self)
        if !err.isEmpty {
            showAlert(err)
        } else if let msg = successMessage {
            showAlert(msg)
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
        if pointsMode == .single {
            stopSimulation(clearAnnotations: false)
            if annotations.count == 2, let second = annotations.last {
                mapView.mkMapView.removeAnnotation(second)
                if let route { mapView.mkMapView.removeOverlay(route.polyline) }
                annotations = [annotations[0]]
            }
        }
    }

    private func handleMapClick(_ sender: NSClickGestureRecognizer) {
        let point = sender.location(in: mapView.mkMapView)
        let coord = mapView.mkMapView.convert(point, toCoordinateFrom: mapView.mkMapView)
        addLocation(coordinate: coord)
    }

    private func addLocation(coordinate: CLLocationCoordinate2D) {
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

        // Single point mode + send location directly when device is ready
        if pointsMode == .single && isDeviceReady {
            run(location: coordinate)
        }
    }

    /// Send location command to the corresponding device
    private func run(location: CLLocationCoordinate2D) {
        // Persist user input
        defaults.set(deviceType, forKey: "device_type")
        defaults.set(adbPath, forKey: "adb_path")
        defaults.set(adbDeviceId, forKey: "adb_device_id")
        defaults.set(isEmulator, forKey: "is_emulator")

        currentRunTask?.cancel()
        let weakAlert: (String) -> Void = { [weak self] msg in
            Task { @MainActor in self?.showAlert(msg) }
        }

        // Android
        if deviceType != 0 {
            currentRunTask = Task {
                await runner.stopCurrentTask()
                if Task.isCancelled { return }
                guard ensureAdbAvailable() else { return }
                logger.debug("Android location: deviceId=\(adbDeviceId), isEmulator=\(isEmulator)")
                await runner.runOnAndroid(
                    location: location,
                    adbDeviceId: adbDeviceId,
                    adbPath: adbPath,
                    isEmulator: isEmulator,
                    showAlert: weakAlert
                )
                if simulationStatus == .idle { simulationStatus = .mocking }
            }
            return
        }

        // iOS Device
        if deviceMode == .device {
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

        // iOS Simulator
        if bootedSimulators.isEmpty {
            simulationStatus = .idle
            showAlert(SimulatorFetchError.noBootedSimulators.description)
            return
        }
        currentRunTask = Task {
            await runner.stopCurrentTask()
            if Task.isCancelled { return }
            runner.runOnSimulator(
                location: location,
                selectedSimulator: selectedSimulator,
                bootedSimulators: bootedSimulators
            )
            if simulationStatus == .idle { simulationStatus = .mocking }
        }
    }
}

// MARK: - Private: List iOS devices

private extension LocationController {

    func getConnectedDevices() async throws -> [Device] {
        let task = try await runner.taskForIOS(args: ["--no-color", "usbmux", "list"])
        let pipe = Pipe()
        task.standardOutput = pipe
        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pipe.fileHandleForReading.closeFile()

        if task.terminationStatus != 0 {
            throw SimulatorFetchError.simctlFailed
        }
        let devices = try JSONDecoder().decode([Device].self, from: data)

        // The same device may appear repeatedly through USB and Network, deduplicate by UDID
        var seen: Set<String> = []
        let unique = devices.filter { seen.insert($0.id).inserted }
        logger.info("Connected devices: \(unique.map { "\($0.name) (\($0.version))" }.joined(separator: ", "))")
        return unique
    }

    func getBootedSimulators() throws -> [Simulator] {
        let task = Process()
        task.launchPath = "/usr/bin/xcrun"
        task.arguments = ["simctl", "list", "-j", "devices"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        pipe.fileHandleForReading.closeFile()

        if task.terminationStatus != 0 { throw SimulatorFetchError.simctlFailed }
        let booted: [Simulator]
        do {
            booted = try JSONDecoder().decode(Simulators.self, from: data).bootedSimulators
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
        // Do not process during Dialog / Alert / text input
        guard pointsMode == .single, !showingAlert, !isShowingDialog else { return }
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
    static let defaultsXcodePathKey = "xcode_path"
    static let developerModeInstructions = """
    Developer Mode needs to be enabled:

    1. Open "Settings" on iPhone
    2. Go to "Privacy & Security"
    3. Scroll to the bottom and tap "Developer Mode"
    4. Turn on the switch and restart the device
    """
}
