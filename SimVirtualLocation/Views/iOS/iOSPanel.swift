//
//  iOSPanel.swift
//  SimVirtualLocation
//

import SwiftUI

struct iOSPanel: View {
    @EnvironmentObject var locationController: LocationController

    var body: some View {
        VStack(spacing: 0) {
            iOSDeviceSettings()
                .environmentObject(locationController)

            PanelDivider()

            LocationSettingsPanel()
                .environmentObject(locationController)
        }
    }
}

// MARK: - Shared design tokens

/// Thin full-width divider used between panel sections.
struct PanelDivider: View {
    var body: some View {
        Divider().padding(.horizontal, -20) // bleed past ContentView's padding
    }
}

/// Small all-caps section label matching macOS Inspector/sidebar conventions.
struct PanelSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor(Color(NSColor.tertiaryLabelColor))
            .tracking(0.5)
    }
}
