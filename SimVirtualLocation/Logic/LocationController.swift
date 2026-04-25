//
//  LocationController.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 21.02.2022.
//

import AppKit
import Combine
import CoreLocation
import MapKit
import MachO

class LocationController: NSObject, ObservableObject, MKMapViewDelegate, CLLocationManagerDelegate, MKLocalSearchCompleterDelegate {

    // MARK: - Enums

    enum DeviceMode: Int, Identifiable {
        case simulator
        case device

        var id: Int { self.rawValue }
    }

    enum PointsMode: Int, Identifiable {
        case single
        case two

        var id: Int { self.rawValue }
    }

    // MARK: - Public

    var alertText: String = ""

    // MARK: - Publishers

    // Feature toggles
    @Published var showAndroidOption: Bool = false
    @Published var showSimulatorOption: Bool = false
    
    enum SimulationType {
        case none
        case route
        case fromAToB
    }

    @Published var simulationType: SimulationType = .none
    @Published var isSimulating = false
    private var lastRunnerUpdateTime: Date = Date.distantPast

    @Published var speed: Double = 60.0
    @Published var pointsMode: PointsMode = .single {
        didSet { handlePointsModeChange() }
    }
    @Published var deviceMode: DeviceMode = .device
    @Published var xcodePath: String = "/Applications/Xcode.app" {
        didSet { defaults.set(xcodePath, forKey: Constants.defaultsXcodePathKey) }
    }

    /// For iOS 17+
    @Published var useRSD: Bool = true

    @Published var bootedSimulators: [Simulator] = []
    @Published var selectedSimulator: String = ""

    @Published var connectedDevices: [Device] = []
    @Published var selectedDevice: String = "" {
        didSet {
            if let device = connectedDevices.first(where: { $0.id == selectedDevice }) {
                let versionComponents = device.version.components(separatedBy: ".")
                if let majorVersion = versionComponents.first, let versionInt = Int(majorVersion) {
                    useRSD = versionInt >= 17
                    log("Selected device version: \(device.version), auto-setting useRSD to \(useRSD)")
                }
            }
        }
    }

    @Published var showingAlert: Bool = false
    @Published var deviceType: Int = 0
    @Published var adbPath: String = ""
    @Published var adbDeviceId: String = ""
    @Published var isEmulator: Bool = false

    @Published var RSDAddress: String = ""
    @Published var RSDPort: String = ""

    @Published var isDeviceActive: Bool = false
    @Published var tunnelStatus: String = ""

    @Published var timeScale: Double = 1.5 {
        didSet { runner.timeDelay = timeScale }
    }

    @Published var logs: [LogEntry] = []

    @Published var searchQuery: String = "" {
        didSet {
            completer.queryFragment = searchQuery
        }
    }
    @Published var searchResults: [MKLocalSearchCompletion] = []

    let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    // MARK: - Private

    private let mapView: MapView
    private let runner = Runner()
    private let currentSimulationAnnotation = MKPointAnnotation()
    private let locationManager = CLLocationManager()
    private let completer = MKLocalSearchCompleter()
    private let defaults: UserDefaults = UserDefaults.standard
    private let iOSDeveloperImagePath = "/Contents/Developer/Platforms/iPhoneOS.platform/DeviceSupport/"
    private let iOSDeveloperImageDmg = "/DeveloperDiskImage.dmg"
    private let iSODeveloperImageSignature = "/DeveloperDiskImage.dmg.signature"

    private var isMapCentered = false

    private var annotations: [MKAnnotation] = []
    private var route: MKRoute?
    
    private var tracks: [Track] = []
    private var currentTrackIndex: Int = 0
    private var lastTrackLocation: CLLocationCoordinate2D?
    private var tracksTimes: [Track: Double] = [:]
    
    private var timer: Timer?
    private var tunnelProcess: Process?

    @Published var savedLocations: [Location] = []

    // MARK: - Init

    init(mapView: MapView) {
        self.mapView = mapView
        super.init()

        completer.delegate = self
        completer.resultTypes = .address

        runner.log = { [unowned self] message in
            self.log(message)
        }

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

    deinit {
        // Terminate tunnel process directly (deinit cannot call async)
        if let process = tunnelProcess, process.isRunning {
            if let stdout = process.standardOutput as? Pipe {
                stdout.fileHandleForReading.readabilityHandler = nil
            }
            if let stderr = process.standardError as? Pipe {
                stderr.fileHandleForReading.readabilityHandler = nil
            }
            process.terminate()
        }
    }

    // MARK: - Public

    @MainActor
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
        guard let location = locationManager.location?.coordinate else {
            showAlert("Current location is unavailable")
            return
        }
        run(location: location)
    }

    func setSelectedLocation() {
        guard let annotation = annotations.first else {
            showAlert("Point A is not selected")
            return
        }
        run(location: annotation.coordinate)
    }

    func makeRoute(autoSimulate: Bool = false) {
        guard annotations.count == 2 else {
            showAlert("Route requires two points")
            return
        }

        let startPoint = annotations[0].coordinate
        let endPoint = annotations[1].coordinate

        let sourcePlacemark = MKPlacemark(coordinate: startPoint, addressDictionary: nil)
        let destinationPlacemark = MKPlacemark(coordinate: endPoint, addressDictionary: nil)

        let sourceMapItem = MKMapItem(placemark: sourcePlacemark)
        let destinationMapItem = MKMapItem(placemark: destinationPlacemark)

        let sourceAnnotation = MKPointAnnotation()

        if let location = sourcePlacemark.location {
            sourceAnnotation.coordinate = location.coordinate
        }

        let destinationAnnotation = MKPointAnnotation()

        if let location = destinationPlacemark.location {
            destinationAnnotation.coordinate = location.coordinate
        }

        self.mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
        self.mapView.mkMapView.showAnnotations([sourceAnnotation, destinationAnnotation], animated: true )

        let directionRequest = MKDirections.Request()
        directionRequest.source = sourceMapItem
        directionRequest.destination = destinationMapItem
        directionRequest.transportType = .automobile

        let directions = MKDirections(request: directionRequest)

        directions.calculate { [weak self] (response, error) -> Void in
            guard let self = self else { return }
            
            Task { @MainActor in
                guard let response = response else {
                    if let error = error {
                        self.showAlert(error.localizedDescription)
                    }
                    return
                }

                let route = response.routes[0]

                if let currentRoute = self.route {
                    self.mapView.mkMapView.removeOverlay(currentRoute.polyline)
                }
                self.route = route
                self.tracks = []
                self.mapView.mkMapView.addOverlay((route.polyline), level: MKOverlayLevel.aboveRoads)

                let rect = route.polyline.boundingMapRect
                self.mapView.mkMapView.setRegion(MKCoordinateRegion(rect.insetBy(dx: -1000, dy: -1000)), animated: true)
                
                if autoSimulate {
                    self.simulateRoute()
                }
            }
        }
    }

    func simulateRoute() {
        guard let route = route else {
            showAlert("No route for simulation")
            return
        }
        
        let buffer = UnsafeBufferPointer(start: route.polyline.points(), count: route.polyline.pointCount)
        
        tracks = []
        for i in 0..<route.polyline.pointCount {
            let trackStartPoint = buffer[i]
            var trackEndPoint: MKMapPoint?
            if i + 1 < route.polyline.pointCount {
                trackEndPoint = buffer[i+1]
            }
            
            if let trackEndPoint = trackEndPoint {
                tracks.append(Track(startPoint: trackStartPoint, endPoint: trackEndPoint))
            }
        }
        
        // prints all tracks distances
        print(tracks.map { CLLocation.distance(from: $0.startPoint.coordinate, to: $0.endPoint.coordinate) })
        
        invalidateState()
        simulationType = .route
        
        let interval = 0.1
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            self.performMovement(stepScale: interval)
        }
        
        self.timer = timer
    }

    func simulateFromAToB() {
        guard annotations.count == 2 else {
            showAlert("Route requires two points")
            return
        }

        let startPoint = annotations[0]
        let endPoint = annotations[1]

        stopSimulation(clearAnnotations: false)
        
        // Create a simple straight line polyline for A to B
        let coordinates = [startPoint.coordinate, endPoint.coordinate]
        let polyline = MKPolyline(coordinates: coordinates, count: 2)
        mapView.mkMapView.addOverlay(polyline, level: .aboveRoads)

        tracks = [Track(startPoint: MKMapPoint(startPoint.coordinate), endPoint: MKMapPoint(endPoint.coordinate))]

        invalidateState()
        isSimulating = true
        simulationType = .fromAToB

        let interval = 0.1
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            self.performMovement(stepScale: interval)
        }

        self.timer = timer
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

        let viewRegion = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)
        let adjustedRegion = mapView.mkMapView.regionThatFits(viewRegion)

        mapView.mkMapView.setRegion(adjustedRegion, animated: true)
        
        mapView.mkMapView.showsUserLocation = true
    }
    
    func prepareEmulator() {
        if adbDeviceId.isEmpty {
            showAlert("Please specify device id")
            return
        }
        
        if adbPath.isEmpty {
            showAlert("Please specify path to adb")
            return
        }
        
        executeAdbCommand(args: ["shell", "settings", "put", "secure", "location_providers_allowed", "+gps"])
        executeAdbCommand(
            args: ["shell", "settings", "put", "secure", "location_providers_allowed", "+network"],
            successMessage: "Emulator is ready"
        )
    }

    func installHelperApp() {
        if adbDeviceId.isEmpty {
            showAlert("Please specify device id")
            return
        }

        if adbPath.isEmpty {
            showAlert("Please specify path to adb")
            return
        }

        let apkPath = Bundle.main.url(forResource: "helper-app", withExtension: "apk")!.path
        let args = ["-s", adbDeviceId, "install", apkPath]

        executeAdbCommand(
            args: args,
            successMessage: "Helper app successfully installed. Please open MockLocationForDeveloper app on your phone and grant all required permissions"
        )
    }

    func stopSimulation(clearAnnotations: Bool = true) {
        isSimulating = false
        simulationType = .none
        Task {
            await runner.stopCurrentTask()
        }
        timer?.invalidate()
        timer = nil
        
        // Clear route and overlays
        mapView.mkMapView.removeOverlays(mapView.mkMapView.overlays)
        self.route = nil
        self.tracks = []
        
        if clearAnnotations {
            mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
            annotations = []
        }
    }

    func selectSearchCompletion(_ completion: MKLocalSearchCompletion) {
        let searchRequest = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: searchRequest)
        search.start { [weak self] response, error in
            guard let self = self, let coordinate = response?.mapItems.first?.placemark.coordinate else { return }
            
            DispatchQueue.main.async {
                self.searchQuery = "" // Clear search
                self.searchResults = []
                self.putLocationOnMap(location: .init(name: completion.title, latitude: coordinate.latitude, longitude: coordinate.longitude))
                
                let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)
                self.mapView.mkMapView.setRegion(region, animated: true)
            }
        }
    }

    // MARK: - MKLocalSearchCompleterDelegate

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        self.searchResults = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        print("Search completion failed: \(error.localizedDescription)")
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        let renderer = MKPolylineRenderer(overlay: overlay)
        renderer.strokeColor = NSColor(red: 17.0/255.0, green: 147.0/255.0, blue: 255.0/255.0, alpha: 1.0)
        renderer.lineWidth = 5.0
        return renderer
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation === currentSimulationAnnotation {
            let identifier = "simulationPuck"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            
            if view == nil {
                view = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view?.canShowCallout = false
                
                // Create a GPS puck style
                let size: CGFloat = 16
                let puck = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
                puck.wantsLayer = true
                puck.layer?.cornerRadius = size / 2
                puck.layer?.backgroundColor = NSColor.orange.cgColor
                puck.layer?.borderWidth = 3
                puck.layer?.borderColor = NSColor.white.cgColor
                
                // Add shadow for depth
                puck.layer?.shadowColor = NSColor.black.cgColor
                puck.layer?.shadowOpacity = 0.3
                puck.layer?.shadowOffset = CGSize(width: 0, height: 2)
                puck.layer?.shadowRadius = 3
                
                view?.addSubview(puck)
                view?.frame = puck.frame
                view?.centerOffset = CGPoint(x: 0, y: 0)
            } else {
                view?.annotation = annotation
            }
            
            return view
        }
        return nil
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        updateMapRegion()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateMapRegion()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print(error.localizedDescription)
    }

    func mountDeveloperImage() {
        guard let device = connectedDevices.first(where: { $0.id == selectedDevice }) else {
            showAlert("No selected device")
            return
        }

        Task { @MainActor in
            self.tunnelStatus = "Mounting..."
            self.isDeviceActive = true

            let mountTask = try await runner.taskForIOS(
                args: [
                    "mounter",
                    "auto-mount",
                    "--udid",
                    device.id
                ],
                showAlert: showAlert
            )

            let pipe = Pipe()
            mountTask.standardOutput = pipe

            let errorPipe = Pipe()
            mountTask.standardError = errorPipe

            do {
                try mountTask.run()
                mountTask.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                pipe.fileHandleForReading.closeFile()

                var errorText = ""
                var isAlreadyMounted = false
                
                if
                    let errorData = try? errorPipe.fileHandleForReading.readToEnd(),
                    let text = String(data: errorData, encoding: .utf8),
                    !text.isEmpty {
                    errorText = text
                    
                    if errorText.range(of: "already mounted", options: .caseInsensitive) != nil ||
                       errorText.range(of: "Image is already mounted", options: .caseInsensitive) != nil {
                        isAlreadyMounted = true
                        log("Device already has developer image mounted")
                    } else if errorText.range(of: "{'Error': 'DeviceLocked'}") != nil {
                        showAlert("Error: Device is locked")
                    } else {
                        showAlert(errorText)
                    }
                }

                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    log(text)
                }

                if mountTask.terminationStatus == 0 || isAlreadyMounted {
                    self.tunnelStatus = "Connected"
                } else {
                    self.isDeviceActive = false
                    self.tunnelStatus = ""
                }
            } catch {
                self.isDeviceActive = false
                self.tunnelStatus = ""
                showAlert(error.localizedDescription)
            }
        }
    }

    func startDevice() {
        if useRSD {
            startRSDTunnel()
        } else {
            mountDeveloperImage()
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
        isSimulating = false
        await runner.stopCurrentTask()

        await runner.resetIos(
            udid: selectedDevice,
            useRSD: false,
            RSDAddress: "",
            RSDPort: "",
            showAlert: showAlert
        )

        await MainActor.run {
            mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
            annotations = []

            if let route = route {
                mapView.mkMapView.removeOverlay(route.polyline)
            }
            
            self.isDeviceActive = false
            self.tunnelStatus = ""
        }
    }

    func startRSDTunnel() {
        guard !isDeviceActive else {
            showAlert("Tunnel is already running")
            return
        }

        guard let password = promptForPassword() else {
            log("RSD tunnel start cancelled by user")
            return
        }

        let deviceId = selectedDevice
        if deviceId.isEmpty {
            showAlert("No device selected")
            return
        }

        // Run tunnel start on background queue to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Get full path to pymobiledevice3
            guard let pymobilePath = self.runner.getFullPathOf("pymobiledevice3") else {
                DispatchQueue.main.async {
                    self.showAlert("pymobiledevice3 not found. Please install it using 'pip install pymobiledevice3' and ensure it's in your PATH.")
                }
                return
            }
            
            // Setup pipes
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            // Create sudo task with pymobiledevice3 command
            let sudoTask = Process()
            sudoTask.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            // For remote start-tunnel, --udid should be passed as a subcommand argument
            sudoTask.arguments = ["-S", pymobilePath, "remote", "start-tunnel", "--udid", deviceId, "--protocol", "tcp"]
            sudoTask.standardInput = inputPipe
            sudoTask.standardOutput = outputPipe
            sudoTask.standardError = errorPipe

            self.log("Starting tunnel for \(deviceId): sudo \(pymobilePath) remote start-tunnel --udid \(deviceId) --protocol tcp")

           DispatchQueue.main.async {
                self.tunnelStatus = "Starting tunnel..."
            }

            // Setup output handler BEFORE starting process
            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.count > 0, let output = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self?.parseRSDOutput(output)
                    }
                }
            }

            // Setup error handler BEFORE starting process
            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.count > 0, let errorText = String(data: data, encoding: .utf8) {
                    let trimmed = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    self?.log("Tunnel Error: \(trimmed)")
                    
                    DispatchQueue.main.async {
                        // Only show alerts for actual errors, not password prompts
                        if !trimmed.isEmpty {
                            if trimmed.contains("incorrect password") || 
                               (trimmed.contains("Sorry, try again") && !trimmed.contains("Password:")) {
                                self?.showAlert("Incorrect sudo password")
                                self?.isDeviceActive = false
                                self?.tunnelStatus = ""
                            } else if trimmed.contains("command not found") || 
                                      trimmed.contains("pymobiledevice3: not found") {
                                self?.showAlert("pymobiledevice3 not found in PATH. Please ensure it's installed.")
                                self?.isDeviceActive = false
                                self?.tunnelStatus = ""
                            }
                        }
                    }
                }
            }

            do {
                // Start the process
                try sudoTask.run()

                // Write password to stdin immediately with proper flushing
                if let passwordData = "\(password)\n".data(using: .utf8) {
                    try inputPipe.fileHandleForWriting.write(contentsOf: passwordData)
                    // Force synchronize to ensure data is written
                    if #available(macOS 10.15.4, *) {
                        try? inputPipe.fileHandleForWriting.synchronize()
                    }
                    
                    // Close the input pipe after writing password
                    try? inputPipe.fileHandleForWriting.close()
                }

                DispatchQueue.main.async {
                    self.tunnelProcess = sudoTask
                    self.isDeviceActive = true
                    self.tunnelStatus = "Authenticating..."
                }

                // Monitor process termination
                sudoTask.terminationHandler = { [weak self] process in
                    DispatchQueue.main.async {
                        self?.isDeviceActive = false
                        self?.tunnelStatus = ""
                        self?.tunnelProcess = nil
                        
                        let status = process.terminationStatus
                        // 15 = SIGTERM from process.terminate(), expected during normal stop
                        if status != 0 && status != 15 {
                            self?.showAlert("Tunnel exited with error code: \(status)")
                        }
                    }
                }

            } catch {
                DispatchQueue.main.async {
                    self.showAlert("Failed to start tunnel: \(error.localizedDescription)")
                    self.isDeviceActive = false
                    self.tunnelStatus = ""
                }
            }
        }
    }

    func stopRSDTunnel() async {
        // 1. Stop any running simulation
        isSimulating = false
        await runner.stopCurrentTask()

        // 2. Clear location simulation on the device (while tunnel is still alive)
        guard let process = tunnelProcess, process.isRunning else {
            DispatchQueue.main.async {
                self.isDeviceActive = false
                self.tunnelStatus = ""
                self.tunnelProcess = nil
            }
            return
        }

        log("Stopping RSD tunnel...")

        await runner.resetIos(
            udid: selectedDevice,
            useRSD: useRSD,
            RSDAddress: RSDAddress,
            RSDPort: RSDPort,
            showAlert: showAlert
        )

        // 3. Clear map annotations and route
        await MainActor.run {
            mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
            annotations = []

            if let route = route {
                mapView.mkMapView.removeOverlay(route.polyline)
            }
        }

        // 4. Terminate the tunnel process
        if let stdout = process.standardOutput as? Pipe {
            stdout.fileHandleForReading.readabilityHandler = nil
        }
        if let stderr = process.standardError as? Pipe {
            stderr.fileHandleForReading.readabilityHandler = nil
        }

        process.terminate()

        await MainActor.run {
            self.tunnelProcess = nil
            self.isDeviceActive = false
            self.tunnelStatus = ""
        }
    }

    func savePointA() {
        guard let point = annotations.first?.coordinate else {
            showAlert("Point A is not selected")
            return
        }

        savedLocations.append(
            Location(
                name: "Point A (\(point.latitude) - \(point.longitude))",
                latitude: point.latitude,
                longitude: point.longitude
            )
        )

        saveSavedLocations()
    }

    func removeLocation(location: Location) {
        savedLocations.removeAll { $0.id == location.id }
        saveSavedLocations()
    }

    func update(_ location: Location, with name: String) {
        guard let locationIndex = savedLocations.firstIndex(where: { $0.id == location.id }) else {
            return
        }

        savedLocations.remove(at: locationIndex)
        savedLocations.insert(
            Location(
                name: name,
                latitude: location.latitude,
                longitude: location.longitude
            ),
            at: locationIndex
        )

        saveSavedLocations()
    }

    func putLocationOnMap(location: Location) {
        addLocation(coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude))
    }

    func showAlert(_ text: String) {
        DispatchQueue.main.async {
            self.alertText = text
            self.showingAlert = true
            self.isSimulating = false
        }
        log("Alert: \(text)")
    }

    func importLocations(from data: Data) {
        let locations = (try? JSONDecoder().decode([Location].self, from: data)) ?? []

        savedLocations.append(contentsOf: locations)
        saveSavedLocations()
    }
    
    func setToCoordinate(latString: String = "", lngString: String = "") {
        // Parse latitude and longitude from strings
        guard let lat = Double(latString), let lng = Double(lngString) else {
            showAlert("Invalid number format. Please enter valid latitude and longitude.")
            return
        }
        
        // Validate coordinate ranges
        // Latitude: -90 (South Pole) to 90 (North Pole)
        // Longitude: -180 (West) to 180 (East)
        guard lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180 else {
            showAlert("Invalid coordinate. Latitude must be between -90 and 90, longitude must be between -180 and 180.")
            return
        }
        
        putLocationOnMap(location: .init(name: "", latitude: lat, longitude: lng))
        run(location: .init(latitude: lat, longitude: lng))
    }
    
    func setToCoordinate(latLngString: String = "") {
        let splitValue = latLngString.components(separatedBy: ",")
     
        guard latLngString.contains(","), splitValue.count == 2 else {
            showAlert("Current location is unavailable")
            return
        }
        
        let latSplitString = splitValue[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let lngSplitString = splitValue[1].trimmingCharacters(in: .whitespacesAndNewlines)
        
        setToCoordinate(latString: latSplitString, lngString: lngSplitString)
    }

    // MARK: - Private

    private func promptForPassword() -> String? {
        let alert = NSAlert()
        alert.messageText = "Enter Password"
        alert.informativeText = "Sudo password is required to start the RSD tunnel."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = passwordField

        alert.window.initialFirstResponder = passwordField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            return passwordField.stringValue
        }
        return nil
    }

    private func parseRSDOutput(_ output: String) {        
        // Parse RSD Address (IPv6 address after "RSD Address:")
        if let addressRange = output.range(of: "RSD Address:\\s*([a-fA-F0-9:]+)", options: .regularExpression) {
            let match = output[addressRange]
            let components = match.components(separatedBy: CharacterSet.whitespaces)
            if components.count >= 2 {
                let address = components.last ?? ""
                if !address.isEmpty && address != RSDAddress {
                    DispatchQueue.main.async { [weak self] in
                        self?.RSDAddress = address
                    }
                }
            }
        }

        // Parse RSD Port (number after "RSD Port:")
        if let portRange = output.range(of: "RSD Port:\\s*(\\d+)", options: .regularExpression) {
            let match = output[portRange]
            let components = match.components(separatedBy: CharacterSet.whitespaces)
            if components.count >= 2 {
                let port = components.last ?? ""
                if !port.isEmpty && port != RSDPort {
                    DispatchQueue.main.async { [weak self] in
                        self?.RSDPort = port
                        self?.tunnelStatus = "Connected"
                        self?.showAlert("RSD tunnel connected!\nAddress: \(self?.RSDAddress ?? "")\nPort: \(port)")
                    }
                }
            }
        }
    }

    private func loadLocations() {
        guard let data = defaults.data(forKey: Constants.defaultsSavedLocationsPathKey) else {
            return
        }

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
        isSimulating = true
        lastTrackLocation = nil
        currentTrackIndex = 0
    }

    private func performMovement(stepScale: Double? = nil) {
        guard self.isSimulating, self.tracks.count > 0, self.currentTrackIndex < self.tracks.count else {
            self.stopSimulation(clearAnnotations: false)
            self.printTimes()
            return
        }

        let currentStepScale = stepScale ?? 0.1
        let track = self.tracks[self.currentTrackIndex]
        let trackMove = track.getNextLocation(
            from: self.lastTrackLocation,
            speed: (self.speed / 3.6) * currentStepScale
        )

        switch trackMove {
            case .moveTo(let to, let from, let speed):
                self.lastTrackLocation = to
                
                // Only send to device every timeScale seconds to avoid flooding
                if Date().timeIntervalSince(lastRunnerUpdateTime) >= timeScale {
                    self.run(location: to)
                    lastRunnerUpdateTime = Date()
                }
                
                // Smoothly update map annotation coordinate
                self.currentSimulationAnnotation.coordinate = to

            case .finishTo(let to, let from, let speed):
                self.lastTrackLocation = nil
                self.currentTrackIndex += 1
                
                self.run(location: to)
                lastRunnerUpdateTime = Date()
                
                self.currentSimulationAnnotation.coordinate = to
        }

        self.tracksTimes[track] = (self.tracksTimes[track] ?? 0) + currentStepScale
        
        // Ensure annotation is on map
        if !self.mapView.mkMapView.annotations.contains(where: { $0 === self.currentSimulationAnnotation }) {
            self.mapView.mkMapView.addAnnotation(self.currentSimulationAnnotation)
        }
    }
    
    private func executeAdbCommand(args: [String], successMessage: String? = nil) {
        if adbDeviceId.isEmpty {
            showAlert("Please specify device id")
            return
        }
        
        if adbPath.isEmpty {
            showAlert("Please specify path to adb")
            return
        }
        
        let task = Process()
        task.executableURL = URL(string: "file://\(adbPath)")!
        task.arguments = args

        let errorPipe = Pipe()

        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            showAlert(error.localizedDescription)
            return
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let error = String(decoding: errorData, as: UTF8.self)

        if !error.isEmpty {
            showAlert(error)
        } else if let successMessage = successMessage {
            showAlert(successMessage)
        }
    }

    private func printTimes() {
        tracksTimes.forEach { track, time in
            let distance = CLLocation.distance(from: track.startPoint.coordinate, to: track.endPoint.coordinate)
            let speed = distance / time
            print("Track result: speed=\(speed * 3.6), distance=\(distance), time=\(time)")
        }
    }

    private func handlePointsModeChange() {
        if pointsMode == .single && annotations.count == 2, let second = annotations.last {
            mapView.mkMapView.removeAnnotation(second)

            if let route = route {
                mapView.mkMapView.removeOverlay(route.polyline)
            }

            annotations = [annotations[0]]
        }
    }

    private func handleMapClick(_ sender: NSClickGestureRecognizer) {
        let point = sender.location(in: mapView.mkMapView)
        handleSet(point: point)
    }

    private func handleSet(point: CGPoint) {
        let clickLocation = mapView.mkMapView.convert(point, toCoordinateFrom: mapView.mkMapView)

        addLocation(coordinate: clickLocation)
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
        annotation.title = annotations.count == 0 ? "A" : "B"

        annotations.append(annotation)
        self.mapView.mkMapView.addAnnotation(annotation)
    }

    private func run(location: CLLocationCoordinate2D) {
        defaults.set(deviceType, forKey: "device_type")
        defaults.set(adbPath, forKey: "adb_path")
        defaults.set(adbDeviceId, forKey: "adb_device_id")
        defaults.set(isEmulator, forKey: "is_emulator")
        
        if deviceType != 0 {
            // Stop previous task asynchronously for Android
            Task {
                await runner.stopCurrentTask()
                do {
                    try runOnAndroid(location: location)
                } catch {
                    showAlert("\(error)")
                }
            }
            return
        }
        
        if deviceMode == .device {
            if useRSD {
                Task {
                    // Stop previous task before starting new one
                    await runner.stopCurrentTask()

                    try await runner.runOnNewIos(
                        location: location,
                        udid: selectedDevice,
                        RSDAddress: RSDAddress,
                        RSDPort: RSDPort,
                        showAlert: showAlert
                    )
                }

            } else {
                Task {
                    // Stop previous task before starting new one
                    await runner.stopCurrentTask()

                    try await runner.runOnIos(
                        location: location,
                        udid: selectedDevice,
                        showAlert: showAlert
                    )
                }
            }
        } else {            if bootedSimulators.isEmpty {
                isSimulating = false
                showAlert(SimulatorFetchError.noBootedSimulators.description)
            }
            // For simulator, stop task in background
            Task {
                await runner.stopCurrentTask()
                runner.runOnSimulator(
                    location: location,
                    selectedSimulator: selectedSimulator,
                    bootedSimulators: bootedSimulators,
                    showAlert: showAlert
                )
            }
        }
    }
    
    private func runOnAndroid(location: CLLocationCoordinate2D) throws {
        if adbDeviceId.isEmpty {
            showAlert("Please specify device id")
            return
        }
        
        if adbPath.isEmpty {
            showAlert("Please specify path to adb")
            return
        }
        
        log("""
        Run on android 
        - location: \(location)
        - adbDeviceId: \(adbDeviceId)
        - adbPath: \(adbPath)
        - isEmulator: \(isEmulator)
        """)
        runner.runOnAndroid(
            location: location,
            adbDeviceId: adbDeviceId,
            adbPath: adbPath,
            isEmulator: isEmulator,
            showAlert: showAlert
        )
    }

    private func makeDeveloperImageDmgPath(iOSVersion: String) -> String {
        return "\(xcodePath)\(iOSDeveloperImagePath)\(iOSVersion)\(iOSDeveloperImageDmg)"
    }

    private func makeDeveloperImageSignaturePath(iOSVersion: String) -> String {
        return "\(xcodePath)\(iOSDeveloperImagePath)\(iOSVersion)\(iSODeveloperImageSignature)"
    }

    private func log(_ message: String) {
        logs.insert(LogEntry(date: Date(), message: message), at: 0)
    }
}

private extension LocationController {

    @MainActor
    private func getConnectedDevices() async throws -> [Device] {
        let task = try await runner.taskForIOS(args: ["--no-color", "usbmux", "list"], showAlert: showAlert)

        log("getConnectedDevices: \(task.executableURL!.absoluteString) \(task.arguments!.joined(separator: " "))")

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
        
        // Deduplicate devices by ID (UDID) to avoid showing same device connected via different methods (USB/Network)
        var uniqueDevices: [Device] = []
        var seenIds: Set<String> = []
        for device in devices {
            if !seenIds.contains(device.id) {
                uniqueDevices.append(device)
                seenIds.insert(device.id)
            }
        }

        log("connected devices: [\(uniqueDevices.map { "\($0.id) \($0.name) \($0.version)" }.joined(separator: ", "))]")

        return uniqueDevices
    }

    private func getBootedSimulators() throws -> [Simulator] {
        let task = Process()
        task.launchPath = "/usr/bin/xcrun"
        task.arguments = ["simctl", "list", "-j", "devices"]

        log("getBootedSimulators: \(task.executableURL!.absoluteString) \(task.arguments!.joined(separator: " "))")

        let pipe = Pipe()
        task.standardOutput = pipe

        task.launch()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        pipe.fileHandleForReading.closeFile()

        if task.terminationStatus != 0 {
            throw SimulatorFetchError.simctlFailed
        }

        let bootedSimulators: [Simulator]

        do {
            bootedSimulators = try JSONDecoder().decode(Simulators.self, from: data).bootedSimulators
        } catch {
            throw SimulatorFetchError.failedToReadOutput
        }

        if bootedSimulators.isEmpty {
            throw SimulatorFetchError.noBootedSimulators
        }

        log("booted simulators: [\(bootedSimulators.map { "\($0.id) \($0.name)" }.joined(separator: ", "))]")

        return [Simulator.empty()] + bootedSimulators
    }

    enum SimulatorFetchError: Error, CustomStringConvertible {
        case simctlFailed
        case failedToReadOutput
        case noBootedSimulators
        case noMatchingSimulators(name: String)
        case noMatchingUDID(udid: UUID)

        var description: String {
            switch self {
            case .simctlFailed:
                return "Running `simctl list` failed"
            case .failedToReadOutput:
                return "Failed to read output from simctl"
            case .noBootedSimulators:
                return "No simulators are currently booted"
            case .noMatchingSimulators(let name):
                return "No booted simulators named '\(name)'"
            case .noMatchingUDID(let udid):
                return "No booted simulators with udid: \(udid.uuidString)"
            }
        }
    }
}

extension CLLocation {

    static func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
        let from = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let to = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return from.distance(from: to)
    }
}

private enum Constants {

    static let defaultsSavedLocationsPathKey = "saved_locations"
    static let defaultsXcodePathKey = "xcode_path"
}
