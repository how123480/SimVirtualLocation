//
//  LocationsView.swift
//  SimVirtualLocation
//

import SwiftUI

struct LocationsView: View {

    @EnvironmentObject var locationController: LocationController

    @State private var renameAlertShowing = false
    @State private var updatedName = ""
    @State private var selectedLocation = Location(name: "", latitude: .zero, longitude: .zero)
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var showAddForm = false
    @State private var newName = ""
    @State private var newLatLng = ""

    var body: some View {
        PanelContainer {
            VStack(alignment: .leading, spacing: 0) {
                header
                if showAddForm {
                    Divider()
                    addForm
                }
                Divider()
                locationList
            }
        }
        .alert("Rename \(selectedLocation.name)", isPresented: $renameAlertShowing) {
            TextField("New name", text: $updatedName)
            Button("Rename") { locationController.update(selectedLocation, with: updatedName) }
            Button("Cancel", role: .cancel) {}
        }
        .fileExporter(
            isPresented: $isExporting,
            document: LocationsFileDocument(locations: locationController.savedLocations),
            contentType: .json,
            defaultFilename: "SimVirtualLocations"
        ) { _ in }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            let fileResult = result.flatMap { url -> Result<Data, Error> in
                _ = url.startAccessingSecurityScopedResource()
                let r = Result { try Data(contentsOf: url) }
                url.stopAccessingSecurityScopedResource()
                return r
            }
            if case .success(let data) = fileResult {
                locationController.importLocations(from: data)
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 6) {
            Text("Saved Locations")
                .font(.callout)
                .fontWeight(.medium)
                .foregroundColor(PanelTheme.textPrimary)

            if !locationController.savedLocations.isEmpty {
                Text("\(locationController.savedLocations.count)")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(PanelTheme.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(PanelTheme.buttonFill)
                    .clipShape(Capsule())
            }

            Spacer()

            PanelIconButton(icon: "square.and.arrow.down", help: "Import locations") {
                isImporting.toggle()
            }
            PanelIconButton(icon: "square.and.arrow.up", help: "Export locations") {
                isExporting.toggle()
            }
            PanelIconButton(
                icon: showAddForm ? "xmark" : "plus",
                help: showAddForm ? "Cancel" : "Add location"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { showAddForm.toggle() }
                if showAddForm { newName = ""; newLatLng = "" }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name (optional)", text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
            TextField("Latitude, Longitude", text: $newLatLng)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
            PanelButton(
                title: "Add",
                style: .prominent,
                disabled: newLatLng.trimmingCharacters(in: .whitespaces).isEmpty
            ) {
                locationController.addSavedLocation(name: newName, latLng: newLatLng)
                newName = ""
                newLatLng = ""
                withAnimation { showAddForm = false }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var locationList: some View {
        if locationController.savedLocations.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(locationController.savedLocations, id: \.id) { location in
                        LocationRow(
                            location: location,
                            onApply:  { locationController.applySavedLocation(location) },
                            onRename: {
                                updatedName = location.name
                                selectedLocation = location
                                renameAlertShowing = true
                            },
                            onDelete: { locationController.removeLocation(location: location) }
                        )
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 60, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "mappin.slash")
                .font(.title3)
                .foregroundColor(PanelTheme.textTertiary)
            Text("No saved locations")
                .font(.caption)
                .foregroundColor(PanelTheme.textSecondary)
            Text("Tap + to add, or use \"Save Point A\"")
                .font(.caption2)
                .foregroundColor(PanelTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - Row

private struct LocationRow: View {
    let location: Location
    let onApply: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(location.name.isEmpty ? "Untitled" : location.name)
                    .font(.callout)
                    .foregroundColor(PanelTheme.textPrimary)
                    .lineLimit(1)
                Text(String(format: "%.5f, %.5f", location.latitude, location.longitude))
                    .font(.caption2)
                    .foregroundColor(PanelTheme.textSecondary)
                    .monospacedDigit()
            }

            Spacer()

            if isHovered {
                HStack(spacing: 2) {
                    PanelIconButton(icon: "map", help: "Place on map", action: onApply)
                    PanelIconButton(icon: "pencil", help: "Rename", action: onRename)
                    PanelIconButton(icon: "trash", help: "Delete", color: .red, action: onDelete)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(PanelTheme.rowFill)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}
