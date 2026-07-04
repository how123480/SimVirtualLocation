//
//  iOSDeviceSettings.swift
//  SimVirtualLocation
//

import SwiftUI

/// DEVICE section: target picker (Simulator | Device), the device card with
/// inline status, and the Connect / Stop button.
struct iOSDeviceSettings: View {
    @EnvironmentObject var locationController: LocationController
    @State private var isRefreshing = false
    @State private var showDevicePicker = false

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

    private var isDeviceMode: Bool {
        locationController.deviceMode == .device
    }

    private var selectedDevice: Device? {
        locationController.connectedDevices.first { $0.id == locationController.selectedDevice }
    }

    private var selectedSimulator: Simulator? {
        locationController.bootedSimulators.first { $0.id == locationController.selectedSimulator }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelSectionLabel(text: "Device")

            if locationController.showSimulatorOption {
                Picker("", selection: $locationController.deviceMode) {
                    Text("Simulator").tag(LocationController.DeviceMode.simulator)
                    Text("Device").tag(LocationController.DeviceMode.device)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            deviceCard

            if isDeviceMode {
                connectButton
            }
        }
        .padding(.vertical, 14)
    }

    // MARK: - Device card

    private var deviceCard: some View {
        DeviceCard(
            icon: isDeviceMode ? "iphone" : "laptopcomputer.and.iphone",
            title: cardTitle,
            status: cardStatus,
            disabled: locationController.deviceStatus.isActive
        ) {
            showDevicePicker = true
        }
        .popover(isPresented: $showDevicePicker, arrowEdge: .bottom) {
            devicePickerPopover
        }
    }

    private var cardTitle: String {
        if isDeviceMode {
            return selectedDevice?.name ?? "No Device"
        }
        return selectedSimulator?.name ?? "No Simulator"
    }

    private var cardStatus: DeviceCard.Status {
        guard isDeviceMode else {
            return .init(text: "iOS Simulator", dotColor: nil)
        }
        guard let device = selectedDevice else {
            return .init(text: "Connect an iPhone via USB", dotColor: nil)
        }
        let prefix = "iOS \(device.version)"
        switch locationController.deviceStatus {
        case .idle:
            return .init(text: "\(prefix) · Disconnected", dotColor: .gray)
        case .connected:
            return .init(text: "\(prefix) · Connected", dotColor: .green)
        case .error(let message):
            let text = message.isEmpty ? "Connection failed" : message
            return .init(text: text, dotColor: .red, isError: true)
        default:
            return .init(
                text: locationController.deviceStatus.displayText,
                dotColor: .orange,
                isLoading: true
            )
        }
    }

    // MARK: - Picker popover

    private var devicePickerPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isDeviceMode {
                if locationController.connectedDevices.isEmpty {
                    PanelEmptyState(
                        icon: "iphone.slash",
                        title: "No devices found",
                        hint: "Connect an iPhone via USB"
                    )
                } else {
                    pickerList(
                        items: locationController.connectedDevices.map {
                            PickerRowModel(id: $0.id, title: $0.name, detail: "iOS \($0.version)")
                        },
                        selectedID: locationController.selectedDevice
                    ) { locationController.selectedDevice = $0 }
                }
            } else {
                if locationController.bootedSimulators.isEmpty {
                    PanelEmptyState(
                        icon: "laptopcomputer.and.iphone",
                        title: "No booted simulators",
                        hint: "Boot a simulator in Xcode"
                    )
                } else {
                    pickerList(
                        items: locationController.bootedSimulators.map {
                            PickerRowModel(id: $0.id, title: $0.name, detail: nil)
                        },
                        selectedID: locationController.selectedSimulator
                    ) { locationController.selectedSimulator = $0 }
                }
            }

            Divider()

            Button {
                guard !isRefreshing else { return }
                isRefreshing = true
                Task {
                    await locationController.refreshDevices()
                    isRefreshing = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                    }
                    Text("Refresh List")
                        .font(.callout)
                    Spacer()
                }
                .foregroundColor(PanelTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 260)
    }

    private func pickerList(
        items: [PickerRowModel],
        selectedID: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(items) { item in
                    Button {
                        onSelect(item.id)
                        showDevicePicker = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.accentColor)
                                .opacity(item.id == selectedID ? 1 : 0)
                                .frame(width: 14)
                            Text(item.title)
                                .font(.callout)
                                .foregroundColor(PanelTheme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            if let detail = item.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundColor(PanelTheme.textSecondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 220)
    }

    // MARK: - Connect button

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

// MARK: - Row model

private struct PickerRowModel: Identifiable {
    let id: String
    let title: String
    let detail: String?
}

// MARK: - Device card

/// Rounded card showing the selected target and its live status; clicking it
/// opens the device picker popover.
private struct DeviceCard: View {
    struct Status {
        let text: String
        let dotColor: Color?
        var isError: Bool = false
        var isLoading: Bool = false
    }

    let icon: String
    let title: String
    let status: Status
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.accentColor)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundColor(PanelTheme.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        if status.isLoading {
                            ProgressView().controlSize(.mini)
                        } else if let dotColor = status.dotColor {
                            Circle()
                                .fill(dotColor)
                                .frame(width: 6, height: 6)
                        }
                        Text(status.text)
                            .font(.caption)
                            .foregroundColor(status.isError ? .red : PanelTheme.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(PanelTheme.textTertiary)
            }
            .padding(10)
            .background(
                isHovered && !disabled ? PanelTheme.buttonFill : PanelTheme.containerFill
            )
            .clipShape(RoundedRectangle(cornerRadius: PanelTheme.radiusContainer, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PanelTheme.radiusContainer, style: .continuous)
                    .stroke(PanelTheme.separator, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(status.isError ? status.text : "")
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}
