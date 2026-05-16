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
        VStack(alignment: .leading, spacing: 0) {
            header
            if showAddForm { addForm }
            locationList
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
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
            Image(systemName: "mappin.and.ellipse")
                .foregroundColor(.accentColor)
                .font(.callout)
            Text("Saved Locations")
                .font(.callout)
                .fontWeight(.semibold)
            if !locationController.savedLocations.isEmpty {
                Text("\(locationController.savedLocations.count)")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }
            Spacer()
            Button(action: { isImporting.toggle() }) {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .help("Import locations")

            Button(action: { isExporting.toggle() }) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help("Export locations")

            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { showAddForm.toggle() }
                if showAddForm { newName = ""; newLatLng = "" }
            }) {
                Image(systemName: showAddForm ? "xmark.circle.fill" : "plus.circle.fill")
                    .foregroundColor(showAddForm ? .secondary : .accentColor)
            }
            .buttonStyle(.borderless)
            .help(showAddForm ? "Cancel" : "Add location")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Image(systemName: "plus.circle")
                    .foregroundColor(.accentColor)
                    .font(.caption)
                Text("Add Location")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.accentColor)
            }
            TextField("Name (optional)", text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
            TextField("Latitude, Longitude", text: $newLatLng)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
            Button(action: {
                locationController.addSavedLocation(name: newName, latLng: newLatLng)
                newName = ""
                newLatLng = ""
                withAnimation { showAddForm = false }
            }) {
                Text("Add")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(newLatLng.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.05))
    }

    private var locationList: some View {
        Group {
            Divider()
            if locationController.savedLocations.isEmpty {
                emptyState
            } else {
                List(locationController.savedLocations, id: \.id) { location in
                    LocationRow(
                        location: location,
                        onApply: { locationController.applySavedLocation(location) },
                        onRename: {
                            updatedName = location.name
                            selectedLocation = location
                            renameAlertShowing = true
                        },
                        onDelete: { locationController.removeLocation(location: location) }
                    )
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
                .listStyle(.plain)
                .frame(minHeight: 60, maxHeight: 220)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "mappin.slash")
                .font(.title3)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
            Text("No saved locations")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Tap + to add, or use \"Save Point A\"")
                .font(.caption2)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
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
            Image(systemName: "mappin.circle.fill")
                .foregroundColor(.red)
                .font(.callout)

            VStack(alignment: .leading, spacing: 1) {
                Text(location.name.isEmpty ? "Untitled" : location.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(String(format: "%.5f, %.5f", location.latitude, location.longitude))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            if isHovered {
                HStack(spacing: 2) {
                    IconButton(icon: "map", help: "Place on map", action: onApply)
                    IconButton(icon: "pencil", help: "Rename", action: onRename)
                    IconButton(icon: "trash", help: "Delete", color: .red, action: onDelete)
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

private struct IconButton: View {
    let icon: String
    let help: String
    var color: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

struct LocationsView_Previews: PreviewProvider {
    static var previews: some View {
        LocationsView()
    }
}
