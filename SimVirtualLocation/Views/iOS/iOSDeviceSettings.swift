//
//  iOSDeviceSettings.swift
//  SimVirtualLocation
//

import SwiftUI

struct iOSDeviceSettings: View {
    @EnvironmentObject var locationController: LocationController
    @State private var isRefreshing = false

    // MARK: - Derived state

    private var statusColor: Color {
        switch locationController.deviceStatus {
        case .connected:   return .green
        case .idle:        return Color(NSColor.quaternaryLabelColor)
        case .error:       return .red
        default:           return .orange
        }
    }

    private var isTransitioning: Bool {
        switch locationController.deviceStatus {
        case .idle, .connected, .error: return false
        default: return true
        }
    }

    private var statusCaption: String? {
        switch locationController.deviceStatus {
        case .idle, .connected: return nil
        case .error(let m): return m.isEmpty ? "Connection failed" : m
        default: return locationController.deviceStatus.displayText
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // ── Simulator / Device toggle ──────────────────────────────────
            if locationController.showSimulatorOption {
                Picker("", selection: $locationController.deviceMode) {
                    Text("Simulator").tag(LocationController.DeviceMode.simulator)
                    Text("Device").tag(LocationController.DeviceMode.device)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            // ── Status dot · picker · refresh ─────────────────────────────
            HStack(spacing: 8) {
                statusDot
                devicePicker
                Spacer(minLength: 0)
                refreshButton
            }

            // ── Status caption ─────────────────────────────────────────────
            if let caption = statusCaption {
                HStack(spacing: 4) {
                    if isTransitioning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                    Text(caption)
                        .font(.caption)
                        .foregroundColor(isTransitioning ? .secondary : .red)
                }
                .padding(.leading, 22)
            }

            // ── Connect / Disconnect CTA ───────────────────────────────────
            if locationController.deviceMode == .device {
                connectButton
            }
        }
        .padding(.vertical, 14)
    }

    // MARK: - Subviews

    private var statusDot: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.18))
                .frame(width: 16, height: 16)
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private var devicePicker: some View {
        if locationController.deviceMode == .device {
            if locationController.connectedDevices.isEmpty {
                Text("No devices found")
                    .font(.callout)
                    .foregroundColor(.secondary)
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

    private var refreshButton: some View {
        Button {
            isRefreshing = true
            Task {
                await locationController.refreshDevices()
                isRefreshing = false
            }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.callout)
        }
        .buttonStyle(.borderless)
        .disabled(locationController.deviceStatus.isActive || isRefreshing)
        .help("Refresh device list")
    }

    @ViewBuilder
    private var connectButton: some View {
        if case .connected = locationController.deviceStatus {
            // Secondary destructive style — bordered with red tint
            Button {
                Task { await locationController.stopDevice() }
            } label: {
                Label("Disconnect", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)

        } else if isTransitioning {
            // Connecting — disabled prominent with spinner
            Button {} label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(locationController.deviceStatus.displayText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(true)

        } else {
            // Idle / error — primary connect action
            Button {
                locationController.startDevice()
            } label: {
                Label("Connect", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
