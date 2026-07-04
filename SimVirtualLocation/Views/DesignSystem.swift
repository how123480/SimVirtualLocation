//
//  DesignSystem.swift
//  SimVirtualLocation
//

import SwiftUI

// MARK: - Tokens

enum PanelTheme {
    // Fills (tinted by primary color so they adapt to light/dark mode)
    static let containerFill      = Color.primary.opacity(0.045)
    static let rowFill            = Color.primary.opacity(0.035)
    static let buttonFill         = Color.primary.opacity(0.11)
    static let buttonFillHover    = Color.primary.opacity(0.16)
    static let buttonFillPressed  = Color.primary.opacity(0.22)

    // Strokes
    static let separator       = Color(NSColor.separatorColor).opacity(0.4)
    static let separatorStrong = Color(NSColor.separatorColor).opacity(0.6)

    // Shape
    static let radius: CGFloat = 6
    static let radiusContainer: CGFloat = 10
    static let radiusPanel: CGFloat = 16

    // Typography colors
    static let textPrimary   = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary  = Color(NSColor.tertiaryLabelColor)
}

// MARK: - Floating map chrome

/// Unified chrome for everything that floats above the map: search bar,
/// results dropdown, zoom cluster, debug log, sidebar handle, side panel.
/// One material, one hairline, one shadow scale — no per-call-site values.
struct MapOverlayChrome: ViewModifier {
    var radius: CGFloat = PanelTheme.radiusContainer
    /// Stronger shadow for the large side panel; small overlays stay light.
    var elevated: Bool = false

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(PanelTheme.separatorStrong, lineWidth: 0.5)
            )
            .shadow(
                color: Color.black.opacity(elevated ? 0.12 : 0.08),
                radius: elevated ? 12 : 4,
                x: 0,
                y: elevated ? 3 : 1
            )
    }
}

extension View {
    func mapOverlayChrome(
        radius: CGFloat = PanelTheme.radiusContainer,
        elevated: Bool = false
    ) -> some View {
        modifier(MapOverlayChrome(radius: radius, elevated: elevated))
    }
}

// MARK: - Section labels & dividers

/// Thin full-width divider used between panel sections (bleeds past container padding).
struct PanelDivider: View {
    var body: some View {
        Divider().padding(.horizontal, -20)
    }
}

/// Small all-caps section label matching macOS Inspector/sidebar conventions.
struct PanelSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor(PanelTheme.textTertiary)
            .tracking(0.5)
    }
}

// MARK: - Unified button

/// Unified button used across all panels.
///
/// Variants:
/// - `.standard`     — subtle neutral fill, primary text
/// - `.prominent`    — accent-tinted fill for primary actions
/// - `.destructive`  — red-tinted fill for stop / disconnect / delete
/// - `.subtle`       — borderless secondary action (used for toolbar icons)
struct PanelButton: View {
    enum Style { case standard, prominent, destructive, subtle }

    let title: String
    var icon: String? = nil
    var style: Style = .standard
    var isLoading: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let icon = icon {
                    Image(systemName: icon).font(.system(size: 12, weight: .medium))
                }
                Text(title)
            }
            .font(.callout)
            .foregroundColor(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: PanelTheme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PanelTheme.radius, style: .continuous)
                    .stroke(strokeColor, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .opacity(disabled ? 0.45 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering in
            guard !disabled else { return }
            isHovered = hovering
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .animation(.easeInOut(duration: 0.08), value: isHovered)
        .animation(.easeInOut(duration: 0.08), value: isPressed)
    }

    private var foreground: Color {
        switch style {
        case .standard:    return PanelTheme.textPrimary
        case .prominent:   return Color.accentColor
        case .destructive: return .red
        case .subtle:      return PanelTheme.textSecondary
        }
    }

    private var background: Color {
        switch style {
        case .standard:
            if isPressed { return PanelTheme.buttonFillPressed }
            return isHovered ? PanelTheme.buttonFillHover : PanelTheme.buttonFill
        case .prominent:
            if isPressed { return Color.accentColor.opacity(0.28) }
            return isHovered ? Color.accentColor.opacity(0.22) : Color.accentColor.opacity(0.15)
        case .destructive:
            if isPressed { return Color.red.opacity(0.28) }
            return isHovered ? Color.red.opacity(0.18) : Color.red.opacity(0.12)
        case .subtle:
            if isPressed { return PanelTheme.buttonFillHover }
            return isHovered ? PanelTheme.buttonFill : .clear
        }
    }

    private var strokeColor: Color {
        switch style {
        case .standard:    return PanelTheme.separator
        case .prominent:   return Color.accentColor.opacity(0.35)
        case .destructive: return Color.red.opacity(0.30)
        case .subtle:      return .clear
        }
    }
}

// MARK: - Icon-only button (header toolbars, row hover actions)

struct PanelIconButton: View {
    let icon: String
    let help: String
    var color: Color = PanelTheme.textSecondary
    var isLoading: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(color)
                }
            }
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered && !disabled ? PanelTheme.buttonFill : .clear)
            )
            .contentShape(Rectangle())
            .opacity(disabled ? 0.45 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Live status pill

/// Small "live" indicator with a pulsing dot. Used to surface that a mocking /
/// simulation is currently active.
struct LiveStatusPill: View {
    let label: String
    var color: Color = .green
    /// Pulses the dot with a radiating halo. Use for active/progressing states
    /// (mocking, connecting); turn off for steady states (connected, error).
    var pulses: Bool = true
    /// Shows a small inline progress spinner instead of the dot.
    var isLoading: Bool = false

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            if isLoading {
                ProgressView().controlSize(.mini)
            } else {
                ZStack {
                    if pulses {
                        Circle()
                            .fill(color.opacity(0.35))
                            .frame(width: 14, height: 14)
                            .scaleEffect(pulse ? 1.4 : 1.0)
                            .opacity(pulse ? 0 : 0.9)
                    }
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                }
                .frame(width: 14, height: 14)
            }
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(PanelTheme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.14))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.5))
        .onAppear {
            guard pulses else { return }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

// MARK: - Empty state

/// Unified empty-state block for lists and popovers: SF Symbol, short title,
/// optional hint line. Centered; callers add frames/padding for their context.
struct PanelEmptyState: View {
    let icon: String
    let title: String
    var hint: String? = nil

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(PanelTheme.textTertiary)
            Text(title)
                .font(.caption)
                .foregroundColor(PanelTheme.textSecondary)
            if let hint = hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundColor(PanelTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - Container backgrounds

/// Subtle rounded container used for grouped content (saved locations, etc.).
struct PanelContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(PanelTheme.containerFill)
            .clipShape(RoundedRectangle(cornerRadius: PanelTheme.radiusContainer, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PanelTheme.radiusContainer, style: .continuous)
                    .stroke(PanelTheme.separator, lineWidth: 0.5)
            )
    }
}
