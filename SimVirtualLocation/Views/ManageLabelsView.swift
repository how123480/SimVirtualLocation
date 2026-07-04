//
//  ManageLabelsView.swift
//  SimVirtualLocation
//

import SwiftUI

/// Modal sheet for managing the user's location labels: add, rename, delete.
/// Label deletion cascades through saved locations (handled in the controller).
struct ManageLabelsView: View {

    @EnvironmentObject var locationController: LocationController
    @Environment(\.dismiss) private var dismiss

    @State private var newLabelName = ""
    @State private var renameTarget: LocationLabel?
    @State private var renameDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            addRow
            Divider()
            listBody
            Divider()
            footer
        }
        .frame(width: 340, height: 420)
        .alert("Rename label", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                if let target = renameTarget {
                    locationController.renameLocationLabel(target, to: renameDraft)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Text("Manage Labels")
                .font(.headline)
                .foregroundColor(PanelTheme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("New label name", text: $newLabelName)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .onSubmit(commitAdd)
            PanelButton(
                title: "Add",
                style: .prominent,
                disabled: newLabelName.trimmingCharacters(in: .whitespaces).isEmpty,
                action: commitAdd
            )
            .frame(maxWidth: 80)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var listBody: some View {
        if locationController.locationLabels.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tag")
                    .font(.title3)
                    .foregroundColor(PanelTheme.textTertiary)
                Text("No labels yet")
                    .font(.caption)
                    .foregroundColor(PanelTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(locationController.locationLabels) { label in
                        labelRow(label)
                    }
                }
                .padding(10)
            }
        }
    }

    private func labelRow(_ label: LocationLabel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "tag.fill")
                .font(.system(size: 10))
                .foregroundColor(PanelTheme.textSecondary)
            Text(label.name)
                .font(.callout)
                .foregroundColor(PanelTheme.textPrimary)
                .lineLimit(1)
            Spacer()
            Text("\(usageCount(label))")
                .font(.caption2)
                .foregroundColor(PanelTheme.textTertiary)
                .monospacedDigit()
            PanelIconButton(icon: "pencil", help: "Rename") {
                renameDraft = label.name
                renameTarget = label
            }
            PanelIconButton(icon: "trash", help: "Delete", color: .red) {
                locationController.removeLocationLabel(label)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(PanelTheme.rowFill)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var footer: some View {
        HStack {
            Spacer()
            PanelButton(title: "Done", style: .standard) { dismiss() }
                .frame(maxWidth: 100)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func commitAdd() {
        guard locationController.addLocationLabel(name: newLabelName) != nil else { return }
        newLabelName = ""
    }

    private func usageCount(_ label: LocationLabel) -> Int {
        locationController.savedLocations.reduce(0) { $0 + ($1.labelIDs.contains(label.id) ? 1 : 0) }
    }
}
