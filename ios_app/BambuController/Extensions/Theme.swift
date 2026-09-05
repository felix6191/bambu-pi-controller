// Theme.swift - Central design system (serious, calm, consistent)
import SwiftUI

enum AppTheme {
    /// Bambu brand green — used sparingly for primary actions & live states
    static let accent = Color(hex: "00B259")
    static let danger = Color.red
    static let warning = Color.orange

    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 12

    static let headline = Font.headline
    static let title2b = Font.title2.bold()
}

/// Rounded card container used across all screens
struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
            )
    }
}

extension View {
    func card() -> some View { modifier(Card()) }
}

/// Primary filled button
struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = AppTheme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1))
            .foregroundColor(.white)
            .cornerRadius(AppTheme.controlRadius)
    }
}

/// Small pill badge (status, LIVE, DEMO, limits)
struct Pill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2).fontWeight(.bold)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

/// Muted explanatory text used in forms and onboarding
struct HintText: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
