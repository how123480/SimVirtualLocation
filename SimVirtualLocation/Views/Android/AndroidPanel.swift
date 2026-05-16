//
//  AndroidPanel.swift
//  SimVirtualLocation
//

import SwiftUI

struct AndroidPanel: View {
    @EnvironmentObject var locationController: LocationController

    var body: some View {
        VStack(spacing: 0) {
            AndroidDeviceSettings()
                .environmentObject(locationController)

            PanelDivider()

            LocationSettingsPanel()
                .environmentObject(locationController)
                .frame(maxHeight: .infinity)
        }
    }
}
