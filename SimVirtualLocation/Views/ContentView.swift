//
//  ContentView.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 20.02.2022.
//

import SwiftUI
import MapKit
#if canImport(Translation)
import Translation
#endif

struct ContentView: View {

    let mapView: MapView
    @ObservedObject var locationController: LocationController
    @State private var showSidePanel: Bool = true
    @State private var isDebugMode: Bool = false
    @State private var eventMonitor: Any?
    @FocusState private var isSearchFocused: Bool

    /// Horizontal space the open side panel occupies (inner width + horizontal
    /// padding; the panel sits flush against the trailing window edge). Kept in
    /// one place so the map centering math and the floating-control offsets
    /// stay in sync.
    private let sidePanelTotalWidth: CGFloat = 340

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Map — bleeds under the hidden title bar.
            mapView
                .ignoresSafeArea()

            if isDebugMode {
                debugLogOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            zoomCluster
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            // Search — top leading; the safe area keeps it below the
            // traffic-light strip.
            searchColumn

            // Side panel (full-height inspector) + collapse handle on its edge.
            HStack(spacing: 0) {
                Spacer()
                    .allowsHitTesting(false) // Allow clicks to pass through Spacer to map and buttons

                // Toggle button (handle)
                Image(systemName: showSidePanel ? "chevron.right" : "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 60)
                    .mapOverlayChrome()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring()) {
                            showSidePanel.toggle()
                        }
                    }
                    .padding(.trailing, showSidePanel ? -12 : 10)
                    .zIndex(1)

                if showSidePanel {
                    sidePanel
                        .transition(.move(edge: .trailing))
                }
            }
            // Full-size so the handle stays vertically centered when the
            // panel is collapsed (the root ZStack aligns topLeading).
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
        .frame(minWidth: 900, minHeight: 620)
        .animation(.spring(), value: showSidePanel)
        .onAppear {
            locationController.mapVisibleInsetRight = showSidePanel ? sidePanelTotalWidth : 0
        }
        .onChange(of: showSidePanel) { newValue in
            locationController.mapVisibleInsetRight = newValue ? sidePanelTotalWidth : 0
        }
        .modifier(Alert(isPresented: $locationController.showingAlert, text: locationController.alertText))
        .onAppear {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                let isKeyDown = event.type == .keyDown

                // Esc (53): Cancel text field focus
                if isKeyDown, event.keyCode == 53 {
                    if isSearchFocused {
                        isSearchFocused = false
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        return nil
                    }
                }

                // Toggle Debug Mode (d)
                if isKeyDown,
                   event.charactersIgnoringModifiers == "d",
                   !event.modifierFlags.contains(.command),
                   !event.modifierFlags.contains(.control),
                   !event.modifierFlags.contains(.option) {

                    if isSearchFocused { return event }
                    if let fr = NSApp.keyWindow?.firstResponder, fr.isKind(of: NSTextView.self) {
                        return event
                    }
                    isDebugMode.toggle()
                    return nil
                }

                // Arrow keys: Joystick
                if [123, 124, 125, 126].contains(event.keyCode) {
                    if isSearchFocused { return event }
                    locationController.handleKeyEvent(event)
                    return event
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        .searchTranslationSupport(locationController)
    }

    init(mapView: MapView, locationController: LocationController) {
        self.mapView = mapView
        self.locationController = locationController
    }

    // MARK: - Debug log overlay

    private var debugLogOverlay: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(locationController.logs.reversed()) { log in
                        // Unified format: [time] [level] [file:line] message
                        Text("[\(locationController.dateFormatter.string(from: log.date))] [\(log.level.label)] [\(log.location)] \(log.message)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary)
                            .id(log.id)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 400)
            .frame(maxHeight: 250)
            .mapOverlayChrome()
            .padding()
            .onChange(of: locationController.logs.count) { _ in
                if let lastId = locationController.logs.first?.id {
                    withAnimation {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let lastId = locationController.logs.first?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Map zoom / locate cluster

    private var zoomCluster: some View {
        VStack(spacing: 0) {
            MapControlButton(icon: "plus") {
                var region: MKCoordinateRegion = mapView.mkMapView.region
                region.span.latitudeDelta /= 2.0
                region.span.longitudeDelta /= 2.0
                mapView.mkMapView.setRegion(region, animated: true)
            }
            Divider().frame(width: 28)
            MapControlButton(icon: "minus") {
                var region: MKCoordinateRegion = mapView.mkMapView.region
                region.span.latitudeDelta *= 2.0
                region.span.longitudeDelta *= 2.0
                mapView.mkMapView.setRegion(region, animated: true)
            }
            Divider().frame(width: 28)
            MapControlButton(icon: "location") {
                locationController.updateMapRegion(force: true)
            }
        }
        .mapOverlayChrome()
        .padding(.bottom, 24)
        .padding(.trailing, showSidePanel ? sidePanelTotalWidth + 16 : 16)
    }

    // MARK: - Search

    private var searchColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.callout)
                    .padding(.leading, 10)
                TextField("Search location", text: $locationController.searchQuery)
                    .focused($isSearchFocused)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.callout)
                    .padding(.vertical, 7)
                    .padding(.trailing, 10)
                    .onSubmit {
                        locationController.performFullSearch()
                    }
            }
            .mapOverlayChrome()
            .padding()

            if (!locationController.searchResults.isEmpty || !locationController.fullSearchResults.isEmpty) && !locationController.searchQuery.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !locationController.fullSearchResults.isEmpty {
                            ForEach(locationController.fullSearchResults, id: \.self) { item in
                                SearchResultRow(
                                    icon: "mappin.and.ellipse",
                                    title: item.name ?? item.placemark.title ?? "Unknown",
                                    subtitle: (item.placemark.title != item.name) ? item.placemark.title : nil
                                ) {
                                    locationController.selectMapItem(item)
                                }
                            }
                        } else {
                            ForEach(locationController.searchResults, id: \.self) { completion in
                                SearchResultRow(
                                    icon: completion.subtitle.contains(",") ? "building.2" : "mappin.and.ellipse",
                                    title: completion.title,
                                    subtitle: completion.subtitle.isEmpty ? nil : completion.subtitle
                                ) {
                                    locationController.selectSearchCompletion(completion)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
                .mapOverlayChrome()
                .padding(.horizontal)
            }
        }
        .frame(width: 300)
    }

    // MARK: - Side panel

    private var sidePanel: some View {
        VStack(spacing: 0) {
            iOSPanel()
                .environmentObject(locationController)
                .frame(maxHeight: .infinity)

            PanelDivider()

            PanelButton(title: "Copy Logs", icon: "doc.on.doc", style: .subtle) {
                let log = locationController.logs.map { entry in
                    let date = locationController.dateFormatter.string(from: entry.date)
                    return "[\(date)] [\(entry.level.label)] [\(entry.location)] \(entry.message)"
                }.joined(separator: "\n")
                let pasteboard = NSPasteboard.general
                pasteboard.declareTypes([.string], owner: nil)
                pasteboard.setString(log, forType: .string)
            }
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .frame(maxHeight: .infinity)
        .background(.thickMaterial)
        .overlay(
            Rectangle()
                .fill(PanelTheme.separatorStrong)
                .frame(width: 0.5),
            alignment: .leading
        )
    }
}

// MARK: - Search query translation (macOS 15+)

#if canImport(Translation)
/// Resolves LocationController's search-translation requests. A
/// `TranslationSession` can only be obtained through SwiftUI's
/// `translationTask` modifier, so the controller publishes a request and
/// this modifier answers it via `completeSearchTranslation(_:)`.
@available(macOS 15.0, *)
private struct SearchTranslationSupport: ViewModifier {
    @ObservedObject var locationController: LocationController
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: locationController.searchTranslationRequest) { _, request in
                guard request != nil else { return }
                if configuration == nil {
                    configuration = TranslationSession.Configuration(
                        target: Locale.Language(identifier: "en")
                    )
                } else {
                    // Re-fires the translationTask action for a new request.
                    configuration?.invalidate()
                }
            }
            .translationTask(configuration) { session in
                guard let request = locationController.searchTranslationRequest else { return }
                let source = Locale.Language(identifier: request.sourceLanguageIdentifier)
                let status = await LanguageAvailability().status(
                    from: source,
                    to: Locale.Language(identifier: "en")
                )
                switch status {
                case .installed:
                    break
                case .supported:
                    // Translating now would show the system model-download
                    // prompt — acceptable only for an explicit Enter-key
                    // search, not the silent as-you-type fallback.
                    guard request.interactive else {
                        locationController.completeSearchTranslation(nil)
                        return
                    }
                default:
                    locationController.completeSearchTranslation(nil)
                    return
                }
                let translated = (try? await session.translate(request.query))?.targetText
                locationController.completeSearchTranslation(translated)
            }
    }
}
#endif

private extension View {
    @ViewBuilder
    func searchTranslationSupport(_ locationController: LocationController) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            modifier(SearchTranslationSupport(locationController: locationController))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

private struct MapControlButton: View {
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: 28, height: 28)
                .background(isHovered ? PanelTheme.buttonFill : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Search result row

private struct SearchResultRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundColor(PanelTheme.textPrimary)
                        .lineLimit(1)
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(PanelTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Divider().padding(.leading, 42)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        let mapView = MapView()
        let locationController = LocationController(mapView: mapView)
        ContentView(mapView: mapView, locationController: locationController)
    }
}

struct Alert: ViewModifier {
    let isPresented: Binding<Bool>
    let text: String

    func body(content: Content) -> some View {
        content
            .alert(text, isPresented: isPresented) {
                Button("OK", role: .cancel) {}
            }
    }
}
