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
        locationController.deviceType == 0 &&
        locationController.deviceMode == .device &&
        !locationController.deviceStatus.isReady
    }

    private var isGPXPath: Bool {
        locationController.deviceType == 0 &&
        locationController.deviceMode == .device &&
        locationController.deviceStatus.isReady
    }

    private var isRouteActive: Bool {
        locationController.simulationStatus == .route ||
        locationController.simulationStatus == .fromAToB
    }

    private var isStopping: Bool {
        locationController.simulationStatus == .stopping
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            modePicker
                .padding(.vertical, 14)

            PanelDivider()

            Group {
                if locationController.pointsMode == .single {
                    singlePointSection
                } else {
                    routeSection
                }
            }
            .disabled(shouldDisableControls)
            .opacity(shouldDisableControls ? 0.4 : 1.0)
            .padding(.vertical, 14)

            PanelDivider()

            LocationsView()
                .environmentObject(locationController)
                .padding(.vertical, 14)
                .frame(maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.25), value: locationController.simulationStatus)
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        Picker("", selection: $locationController.pointsMode) {
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
        Button {
            locationController.savePointA()
        } label: {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(PanelTheme.textPrimary)
                .frame(width: 30, height: 26)
                .background(PanelTheme.buttonFill)
                .clipShape(RoundedRectangle(cornerRadius: PanelTheme.radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: PanelTheme.radius, style: .continuous)
                        .stroke(PanelTheme.separator, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help("Save Point A")
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
        Button {
            Task { await locationController.stopSimulation(clearAnnotations: false) }
        } label: {
            Group {
                if isStoppingMocking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.red)
                }
            }
            .frame(width: 30, height: 26)
            .background(Color.red.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: PanelTheme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PanelTheme.radius, style: .continuous)
                    .stroke(Color.red.opacity(0.35), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isStoppingMocking)
        .help("Stop Mocking A")
    }

    // MARK: - Route section

    private var routeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Action buttons on top
            VStack(spacing: 6) {
                simulateRouteButton
                atoBButton
            }

            Divider()

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
            }

            // Update interval (or GPX note)
            if isGPXPath {
                Text("GPX playback — speed updates live without restarting")
                    .font(.caption)
                    .foregroundColor(PanelTheme.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    PanelSectionLabel(text: "Update Interval")
                    if locationController.useRSD {
                        Picker("", selection: $locationController.timeScale) {
                            Text("5 s").tag(5.0)
                            Text("10 s").tag(10.0)
                            Text("15 s").tag(15.0)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .onAppear { locationController.timeScale = 5.0 }
                    } else {
                        Picker("", selection: $locationController.timeScale) {
                            Text("1 s").tag(1.0)
                            Text("1.5 s").tag(1.5)
                            Text("2 s").tag(2.0)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }
            }
        }
    }

    // MARK: - Route action buttons

    private var simulateRouteButton: some View {
        let isActive = locationController.simulationStatus == .route
        let stopping = isStopping && isActive
        let label = stopping ? "Stopping…" : isActive ? "Stop Route" : "Simulate Route"
        let style: PanelButton.Style = isActive ? .destructive : .prominent
        let action: () -> Void = isActive
            ? { Task { await locationController.stopSimulation() } }
            : { locationController.makeRoute(autoSimulate: true) }
        let disabled = (locationController.simulationStatus == .fromAToB && !isActive) || stopping
        return PanelButton(
            title: label,
            style: style,
            isLoading: stopping,
            disabled: disabled,
            action: action
        )
    }

    private var atoBButton: some View {
        let isActive = locationController.simulationStatus == .fromAToB
        let stopping = isStopping && isActive
        let label = stopping ? "Stopping…" : isActive ? "Stop A→B" : "A→B Linear"
        let style: PanelButton.Style = isActive ? .destructive : .prominent
        let action: () -> Void = isActive
            ? { Task { await locationController.stopSimulation() } }
            : { locationController.simulateFromAToB() }
        let disabled = (locationController.simulationStatus == .route && !isActive) || stopping
        return PanelButton(
            title: label,
            style: style,
            isLoading: stopping,
            disabled: disabled,
            action: action
        )
    }
}
