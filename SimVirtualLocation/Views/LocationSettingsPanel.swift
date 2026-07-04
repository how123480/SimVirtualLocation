//
//  LocationSettingsPanel.swift
//  SimVirtualLocation
//

import SwiftUI
import Foundation

struct LocationSettingsPanel: View {
    @EnvironmentObject var locationController: LocationController

    @State private var latitudeLongitude = ""

    // MARK: - Derived state

    private var shouldDisableControls: Bool {
        locationController.deviceMode == .device &&
        !locationController.deviceStatus.isReady
    }

    private var isRouteActive: Bool {
        switch locationController.simulationStatus {
        case .route, .fromAToB, .routePaused, .fromAToBPaused: return true
        default: return false
        }
    }

    private var isStopping: Bool {
        locationController.simulationStatus == .stopping
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader

                modePicker

                Group {
                    if locationController.pointsMode == .single {
                        singlePointSection
                    } else {
                        routeSection
                    }
                }
                .disabled(shouldDisableControls)
                .opacity(shouldDisableControls ? 0.4 : 1.0)
            }
            .padding(.vertical, 14)

            PanelDivider()

            LocationsView()
                .environmentObject(locationController)
                .padding(.vertical, 14)
                .frame(maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.25), value: locationController.simulationStatus)
    }

    // MARK: - Section header

    private var sectionHeader: some View {
        HStack {
            PanelSectionLabel(text: "Simulation")
            Spacer()
            simulationPill
        }
    }

    /// Compact live state for the section — replaces the old top-of-panel
    /// status pills; device state now lives on the device card.
    private var simulationPill: some View {
        let status = locationController.simulationStatus
        switch status {
        case .idle:
            return LiveStatusPill(label: "Idle", color: .gray, pulses: false)
        case .mocking:
            return LiveStatusPill(label: "Mocking", color: .green)
        case .route:
            return LiveStatusPill(label: "Route", color: .green)
        case .fromAToB:
            return LiveStatusPill(label: "A→B", color: .green)
        case .routePaused, .fromAToBPaused:
            return LiveStatusPill(label: "Paused", color: .orange, pulses: false)
        case .stopping:
            return LiveStatusPill(label: "Stopping…", color: .orange, pulses: false, isLoading: true)
        }
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        // Bind through the gate (not directly to `pointsMode`) so a switch
        // while mocking is vetoed before it happens, leaving the running
        // simulation untouched.
        Picker("", selection: Binding(
            get: { locationController.pointsMode },
            set: { locationController.requestPointsModeChange($0) }
        )) {
            Text("Single Point").tag(LocationController.PointsMode.single)
            Text("Route").tag(LocationController.PointsMode.two)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    // MARK: - Single Point section

    private var singlePointSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelButton(title: "Set to Current Location") {
                locationController.setCurrentLocation()
            }

            PanelButton(title: "Enter Coordinates") {
                latitudeLongitude = ""
                locationController.isShowingDialog = true
            }
            .alert("Enter Coordinates", isPresented: $locationController.isShowingDialog) {
                TextField("Latitude, Longitude", text: $latitudeLongitude)
                Button("Move") {
                    locationController.setToCoordinate(latLngString: latitudeLongitude)
                }
                Button("Cancel", role: .cancel) {}
            }

            HStack(spacing: 8) {
                applyToAButton
                if isMockingActive || isStoppingMocking {
                    stopMockingIconButton
                }
                saveIconButton
            }

            if isRouteActive {
                Text("Map locked during route simulation")
                    .font(.caption)
                    .foregroundColor(PanelTheme.textSecondary)
                    .padding(.top, 2)
            }
        }
    }

    private var saveIconButton: some View {
        PanelIconButton(icon: "square.and.arrow.down", help: "Save Point A") {
            locationController.savePointA()
        }
    }

    // MARK: - Single-point apply / stop

    private var isMockingActive: Bool {
        locationController.simulationStatus == .mocking
    }

    private var isStoppingMocking: Bool {
        isStopping && isMockingActive
    }

    private var applyToAButton: some View {
        PanelButton(
            title: "Apply to A",
            style: .prominent,
            disabled: isRouteActive || isStoppingMocking,
            action: { locationController.setSelectedLocation() }
        )
    }

    private var stopMockingIconButton: some View {
        PanelIconButton(
            icon: "stop.fill",
            help: "Stop Mocking A",
            color: .red,
            isLoading: isStoppingMocking,
            disabled: isStoppingMocking
        ) {
            Task { await locationController.stopSimulation(clearAnnotations: false) }
        }
    }

    // MARK: - Route section

    private var routeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Action buttons on top
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    simulateRouteButton
                    if isRoutePauseVisible {
                        pauseResumeIconButton
                    }
                }
                HStack(spacing: 8) {
                    atoBButton
                    if isAtoBPauseVisible {
                        pauseResumeIconButton
                    }
                }
            }

            // Speed slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    PanelSectionLabel(text: "Speed")
                    Spacer()
                    Text("\(Int(locationController.speed.rounded(.up))) km/h")
                        .font(.callout)
                        .foregroundColor(PanelTheme.textSecondary)
                        .monospacedDigit()
                }
                Slider(value: $locationController.speed, in: 5...200, step: 5)
                    .controlSize(.small)
                    .tint(.accentColor)
            }
        }
    }

    // MARK: - Route action buttons

    private var simulateRouteButton: some View {
        let status = locationController.simulationStatus
        let isActive = status == .route || status == .routePaused
        let stopping = isStopping && isActive
        let label = stopping ? "Stopping…" : isActive ? "Stop Route" : "Simulate Route"
        let style: PanelButton.Style = isActive ? .destructive : .prominent
        let action: () -> Void = isActive
            ? { Task { await locationController.stopSimulation() } }
            : { locationController.makeRoute(autoSimulate: true) }
        let crossActive = status == .fromAToB || status == .fromAToBPaused
        let disabled = (crossActive && !isActive) || stopping
        return PanelButton(
            title: label,
            style: style,
            isLoading: stopping,
            disabled: disabled,
            action: action
        )
    }

    private var atoBButton: some View {
        let status = locationController.simulationStatus
        let isActive = status == .fromAToB || status == .fromAToBPaused
        let stopping = isStopping && isActive
        let label = stopping ? "Stopping…" : isActive ? "Stop A→B" : "A→B Linear"
        let style: PanelButton.Style = isActive ? .destructive : .prominent
        let action: () -> Void = isActive
            ? { Task { await locationController.stopSimulation() } }
            : { locationController.simulateFromAToB() }
        let crossActive = status == .route || status == .routePaused
        let disabled = (crossActive && !isActive) || stopping
        return PanelButton(
            title: label,
            style: style,
            isLoading: stopping,
            disabled: disabled,
            action: action
        )
    }

    // MARK: - Pause / Resume icon

    private var isRoutePauseVisible: Bool {
        let status = locationController.simulationStatus
        return status == .route || status == .routePaused
    }

    private var isAtoBPauseVisible: Bool {
        let status = locationController.simulationStatus
        return status == .fromAToB || status == .fromAToBPaused
    }

    private var pauseResumeIconButton: some View {
        let isPaused = locationController.simulationStatus.isPaused
        return PanelIconButton(
            icon: isPaused ? "play.fill" : "pause.fill",
            help: isPaused ? "Resume" : "Pause",
            color: isPaused ? .green : PanelTheme.textSecondary,
            disabled: isStopping
        ) {
            if isPaused {
                locationController.resumeRouteSimulation()
            } else {
                Task { await locationController.pauseRouteSimulation() }
            }
        }
    }
}
