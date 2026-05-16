//
//  iOSPanel.swift
//  SimVirtualLocation
//

import SwiftUI

struct iOSPanel: View {
    @EnvironmentObject var locationController: LocationController

    var body: some View {
        VStack(spacing: 0) {
            StatusPanel(
                deviceStatus: locationController.deviceStatus,
                simulationStatus: locationController.simulationStatus
            )
            .padding(.top, 2)
            .padding(.bottom, 14)

            PanelDivider()

            iOSDeviceSettings()
                .environmentObject(locationController)

            PanelDivider()

            LocationSettingsPanel()
                .environmentObject(locationController)
                .frame(maxHeight: .infinity)
        }
    }
}

/// Compact status zone — one row for device state, one for simulation state.
struct StatusPanel: View {
    let deviceStatus: DeviceStatus
    let simulationStatus: SimulationStatus

    var body: some View {
        StatusSection(rows: [deviceRow, simulationRow])
            .animation(.easeInOut(duration: 0.25), value: deviceStatus)
            .animation(.easeInOut(duration: 0.25), value: simulationStatus)
    }

    private var deviceRow: StatusSection.Row {
        switch deviceStatus {
        case .idle:
            return .init(pillLabel: "Disconnected", color: .gray, pulses: false)
        case .connected:
            return .init(pillLabel: "Connected", color: .green, pulses: false)
        case .error(let m):
            let text = m.isEmpty ? "Connection failed" : m
            return .init(pillLabel: text, color: .red, pulses: false)
        default:
            return .init(
                pillLabel: deviceStatus.displayText,
                color: .orange,
                pulses: false,
                isLoading: true
            )
        }
    }

    private var simulationRow: StatusSection.Row {
        switch simulationStatus {
        case .idle:
            return .init(pillLabel: "Idle", color: .gray, pulses: false)
        case .mocking:
            return .init(pillLabel: "Mocking Point A", color: .green)
        case .route:
            return .init(pillLabel: "Simulating Route", color: .green)
        case .fromAToB:
            return .init(pillLabel: "Simulating A→B", color: .green)
        case .stopping:
            return .init(
                pillLabel: "Stopping…",
                color: .orange,
                pulses: false,
                isLoading: true
            )
        }
    }
}
