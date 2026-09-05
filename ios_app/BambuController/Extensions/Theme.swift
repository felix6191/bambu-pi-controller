// Theme.swift - Central design system (serious, calm, consistent)
import SwiftUI

enum AppTheme {
    /// Bambu brand green — adaptive for light/dark (HIG Dark Mode). Used for
    /// primary actions & confirmed-live states only, never bare decoration.
    static let accent = Color.adaptiveAccent
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

/// Guarantees the 44pt minimum touch target (HIG Accessibility > Mobility)
struct TouchTarget: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

extension View {
    func touchTarget() -> some View { modifier(TouchTarget()) }
}

/// Muted explanatory text used in forms and onboarding
struct HintText: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// One command result shown as a dismissible banner (callback feedback)
struct CommandFeedback: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let ok: Bool
    static func == (lhs: CommandFeedback, rhs: CommandFeedback) -> Bool { lhs.id == rhs.id }
}

struct FeedbackBanner: View {
    let feedback: CommandFeedback
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: feedback.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundColor(feedback.ok ? AppTheme.accent : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(feedback.title).font(.subheadline).fontWeight(.semibold)
                Text(feedback.message).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(feedback.ok ? AppTheme.accent.opacity(0.5) : Color.orange.opacity(0.6), lineWidth: 1)
        )
    }
}
