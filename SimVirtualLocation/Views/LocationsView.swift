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
    @State private var showManageLabels = false
    /// nil = "All". Otherwise filters list to locations carrying this label.
    @State private var selectedLabelID: UUID?

    private var filteredLocations: [Location] {
        guard let id = selectedLabelID else { return locationController.savedLocations }
        return locationController.savedLocations.filter { $0.labelIDs.contains(id) }
    }

    var body: some View {
        PanelContainer {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                filterChipsRow
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
        .sheet(isPresented: $showManageLabels) {
            ManageLabelsView()
                .environmentObject(locationController)
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

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FilterChip(
                    label: "All",
                    isSelected: selectedLabelID == nil
                ) {
                    selectedLabelID = nil
                }

                ForEach(locationController.locationLabels) { label in
                    FilterChip(
                        label: label.name,
                        isSelected: selectedLabelID == label.id
                    ) {
                        selectedLabelID = (selectedLabelID == label.id) ? nil : label.id
                    }
                }

                Button {
                    showManageLabels = true
                } label: {
                    Image(systemName: "tag")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(PanelTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(PanelTheme.buttonFill)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Manage labels")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .onChange(of: locationController.locationLabels) { labels in
            if let id = selectedLabelID, !labels.contains(where: { $0.id == id }) {
                selectedLabelID = nil
            }
        }
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
        } else if filteredLocations.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.title3)
                    .foregroundColor(PanelTheme.textTertiary)
                Text("No locations under this label")
                    .font(.caption)
                    .foregroundColor(PanelTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredLocations, id: \.id) { location in
                        LocationRow(
                            location: location,
                            allLabels: locationController.locationLabels,
                            onApply:  { locationController.applySavedLocation(location) },
                            onRename: {
                                updatedName = location.name
                                selectedLocation = location
                                renameAlertShowing = true
                            },
                            onDelete: { locationController.removeLocation(location: location) },
                            onToggleLabel: { label in
                                locationController.toggleLabel(label, on: location)
                            },
                            onManageLabels: { showManageLabels = true }
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

// MARK: - Filter chip

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected
                    ? Color(NSColor.alternateSelectedControlTextColor)
                    : PanelTheme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isSelected
                        ? Color.accentColor
                        : (isHovered ? PanelTheme.buttonFillHover : PanelTheme.buttonFill))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Row

private struct LocationRow: View {
    let location: Location
    let allLabels: [LocationLabel]
    let onApply: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onToggleLabel: (LocationLabel) -> Void
    let onManageLabels: () -> Void

    @State private var isHovered = false
    @State private var showLabelPicker = false

    private var assignedLabels: [LocationLabel] {
        allLabels.filter { location.labelIDs.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(location.name.isEmpty ? "Untitled" : location.name)
                    .font(.callout)
                    .foregroundColor(PanelTheme.textPrimary)
                    .lineLimit(1)
                Text(String(format: "%.5f, %.5f", location.latitude, location.longitude))
                    .font(.caption2)
                    .foregroundColor(PanelTheme.textSecondary)
                    .monospacedDigit()
                if !assignedLabels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(assignedLabels.prefix(3)) { label in
                            Text(label.name)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(PanelTheme.textSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(PanelTheme.buttonFill)
                                .clipShape(Capsule())
                        }
                        if assignedLabels.count > 3 {
                            Text("+\(assignedLabels.count - 3)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(PanelTheme.textTertiary)
                        }
                    }
                    .padding(.top, 1)
                }
            }

            Spacer()

            if isHovered || showLabelPicker {
                HStack(spacing: 2) {
                    PanelIconButton(icon: "tag", help: "Labels") {
                        showLabelPicker = true
                    }
                    .popover(isPresented: $showLabelPicker, arrowEdge: .trailing) {
                        LabelPickerPopover(
                            allLabels: allLabels,
                            assignedIDs: Set(location.labelIDs),
                            onToggle: onToggleLabel,
                            onManage: {
                                showLabelPicker = false
                                onManageLabels()
                            }
                        )
                    }
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

// MARK: - Label picker popover

private struct LabelPickerPopover: View {
    let allLabels: [LocationLabel]
    let assignedIDs: Set<UUID>
    let onToggle: (LocationLabel) -> Void
    let onManage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if allLabels.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tag")
                        .font(.title3)
                        .foregroundColor(PanelTheme.textTertiary)
                    Text("No labels yet")
                        .font(.caption)
                        .foregroundColor(PanelTheme.textSecondary)
                }
                .frame(width: 200, height: 80)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(allLabels) { label in
                            Button {
                                onToggle(label)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: assignedIDs.contains(label.id) ? "checkmark.square.fill" : "square")
                                        .foregroundColor(assignedIDs.contains(label.id) ? .accentColor : PanelTheme.textTertiary)
                                        .font(.system(size: 12))
                                    Text(label.name)
                                        .font(.callout)
                                        .foregroundColor(PanelTheme.textPrimary)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(width: 220, height: min(CGFloat(allLabels.count) * 28 + 12, 240))
            }
            Divider()
            Button(action: onManage) {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                    Text("Manage Labels…")
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
    }
}
