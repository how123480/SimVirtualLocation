//
//  iOSPanel.swift
//  SimVirtualLocation
//

import SwiftUI

/// Inspector content: Device section, then Simulation + Saved Locations.
/// Status is contextual — device state lives on the device card
/// (`iOSDeviceSettings`), simulation state on the Simulation section header
/// (`LocationSettingsPanel`).
struct iOSPanel: View {
    @EnvironmentObject var locationController: LocationController

    var body: some View {
        VStack(spacing: 0) {
            iOSDeviceSettings()
                .environmentObject(locationController)

            PanelDivider()

            LocationSettingsPanel()
                .environmentObject(locationController)
                .frame(maxHeight: .infinity)
        }
    }
}
