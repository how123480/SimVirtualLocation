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

    /// Dims/disables the whole section when iOS device isn't connected yet.
    private var shouldDisableControls: Bool {
        locationController.deviceType == 0 &&
        locationController.deviceMode == .device &&
        !locationController.deviceStatus.isReady
    }

    /// iOS physical device connected → pymobiledevice3 drives playback; no interval picker.
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
            // ── Mode selector ──────────────────────────────────────────────
            modePicker
                .padding(.vertical, 14)

            PanelDivider()

            // ── Mode controls ──────────────────────────────────────────────
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

            // ── Saved locations ────────────────────────────────────────────
            LocationsView()
                .environmentObject(locationController)
                .padding(.top, 6)
        }
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
            // Primary location actions (full width)
            PanelActionButton(
                title: "Set to Current Location",
                icon: "location.fill"
            ) {
                locationController.setCurrentLocation()
            }

            PanelActionButton(
                title: "Enter Coordinates…",
                icon: "plus.viewfinder"
            ) {
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

            Divider().padding(.vertical, 2)

            // Secondary row (half width each)
            HStack(spacing: 8) {
                PanelActionButton(title: "Apply to A", icon: "scope") {
                    locationController.setSelectedLocation()
                }
                PanelActionButton(title: "Save Point A", icon: "bookmark.fill") {
                    locationController.savePointA()
                }
            }

            if isRouteActive {
                Label("Map locked during route simulation", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Route section

    private var routeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Speed slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    PanelSectionLabel(text: "Speed")
                    Spacer()
                    Text("\(Int(locationController.speed.rounded(.up))) km/h")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $locationController.speed, in: 5...200, step: 5)
                    .controlSize(.small)
            }

            // Update interval (or GPX note)
            if isGPXPath {
                Label("GPX playback — speed updates live without restarting", systemImage: "waveform.path")
                    .font(.caption)
                    .foregroundColor(.secondary)
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

            Divider()

            // Simulation action buttons
            VStack(spacing: 6) {
                simulateRouteButton
                atoBButton
            }
        }
    }

    // MARK: - Route action buttons

    @ViewBuilder
    private var simulateRouteButton: some View {
        let isActive = locationController.simulationStatus == .route
        let label = isStopping ? "Stopping…" : isActive ? "Stop Route" : "Simulate Route"
        let icon  = isActive ? "stop.fill" : "play.fill"

        if isActive {
            Button { Task { await locationController.stopSimulation() } } label: {
                routeButtonLabel(text: label, icon: icon)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(isStopping)
        } else {
            Button { locationController.makeRoute(autoSimulate: true) } label: {
                routeButtonLabel(text: label, icon: icon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(locationController.simulationStatus == .fromAToB || isStopping)
        }
    }

    @ViewBuilder
    private var atoBButton: some View {
        let isActive = locationController.simulationStatus == .fromAToB
        let label = isStopping ? "Stopping…" : isActive ? "Stop A→B" : "A→B Linear"
        let icon  = isActive ? "stop.fill" : "arrow.forward.circle.fill"

        if isActive {
            Button { Task { await locationController.stopSimulation() } } label: {
                routeButtonLabel(text: label, icon: icon)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(isStopping)
        } else {
            Button { locationController.simulateFromAToB() } label: {
                routeButtonLabel(text: label, icon: icon)
            }
            .buttonStyle(.bordered)
            .disabled(locationController.simulationStatus == .route || isStopping)
        }
    }

    private func routeButtonLabel(text: String, icon: String) -> some View {
        HStack(spacing: 6) {
            if isStopping {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: icon)
            }
            Text(text)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shared button component

/// Full-width bordered action button used throughout the panel.
private struct PanelActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }
}

