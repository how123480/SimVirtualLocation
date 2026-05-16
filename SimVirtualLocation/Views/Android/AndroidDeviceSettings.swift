//
//  AndroidDeviceSettings.swift
//  SimVirtualLocation
//

import SwiftUI

struct AndroidDeviceSettings: View {
    @EnvironmentObject var locationController: LocationController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                PanelSectionLabel(text: "ADB")
                TextField("/usr/local/bin/adb", text: $locationController.adbPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                TextField("Device ID", text: $locationController.adbDeviceId)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
            }

            Toggle("Emulator", isOn: $locationController.isEmulator)
                .toggleStyle(.switch)
                .font(.callout)
                .foregroundColor(PanelTheme.textPrimary)

            PanelButton(
                title: locationController.isEmulator ? "Prepare Emulator" : "Install Helper App",
                style: .prominent
            ) {
                if locationController.isEmulator {
                    locationController.prepareEmulator()
                } else {
                    locationController.installHelperApp()
                }
            }
        }
        .padding(.vertical, 14)
    }
}
