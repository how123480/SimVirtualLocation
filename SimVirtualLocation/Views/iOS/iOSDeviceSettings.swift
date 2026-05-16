//
//  iOSDeviceSettings.swift
//  SimVirtualLocation
//

import SwiftUI

struct iOSDeviceSettings: View {
    @EnvironmentObject var locationController: LocationController
    @State private var isRefreshing = false

    // MARK: - Derived state

    private var isTransitioning: Bool {
        switch locationController.deviceStatus {
        case .idle, .connected, .error: return false
        default: return true
        }
    }

    private var isConnected: Bool {
        if case .connected = locationController.deviceStatus { return true }
        return false
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if locationController.showSimulatorOption {
                Picker("", selection: $locationController.deviceMode) {
                    Text("Simulator").tag(LocationController.DeviceMode.simulator)
                    Text("Device").tag(LocationController.DeviceMode.device)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            HStack(spacing: 8) {
                devicePicker
                Spacer(minLength: 0)
                PanelIconButton(icon: "arrow.clockwise", help: "Refresh device list") {
                    isRefreshing = true
                    Task {
                        await locationController.refreshDevices()
                        isRefreshing = false
                    }
                }
                .disabled(locationController.deviceStatus.isActive || isRefreshing)
            }

            if locationController.deviceMode == .device {
                connectButton
            }
        }
        .padding(.vertical, 14)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var devicePicker: some View {
        if locationController.deviceMode == .device {
            if locationController.connectedDevices.isEmpty {
                Text("No devices found")
                    .font(.callout)
                    .foregroundColor(PanelTheme.textSecondary)
            } else {
                Picker("", selection: $locationController.selectedDevice) {
                    ForEach(locationController.connectedDevices, id: \.id) { d in
                        Text("\(d.name)  \(d.version)").tag(d.id)
                    }
                }
                .labelsHidden()
                .disabled(locationController.deviceStatus.isActive)
            }
        } else {
            Picker("", selection: $locationController.selectedSimulator) {
                ForEach(locationController.bootedSimulators, id: \.id) { s in
                    Text(s.name).tag(s.id)
                }
            }
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var connectButton: some View {
        if isTransitioning {
            PanelButton(
                title: locationController.deviceStatus.displayText,
                style: .standard,
                isLoading: true,
                disabled: true,
                action: {}
            )
        } else if isConnected {
            PanelButton(title: "Stop", icon: "stop.fill", style: .destructive) {
                Task { await locationController.stopDevice() }
            }
        } else {
            PanelButton(title: "Start", icon: "play.fill", style: .prominent) {
                locationController.startDevice()
            }
        }
    }
}
