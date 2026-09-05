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

/// Brand font: Space Grotesk (Google Fonts, OFL) — geometric, techy, playful.
/// Delivered as variable TTF in Resources/Fonts, registered via UIAppFonts.
extension Font {
    static func brand(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .custom("Space Grotesk", size: size).weight(weight)
    }
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

/// Primary filled button — monochrome adaptive (black in light, white in dark),
/// like premium companion apps. Accent green stays reserved for status/success.
/// Pass `color` only for semantic cases (e.g. destructive red).
struct PrimaryButtonStyle: ButtonStyle {
    var color: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        let bg = color ?? Color.primary
        let fg: Color = color == nil ? Color(.systemBackground) : .white
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(bg.opacity(configuration.isPressed ? 0.7 : 1))
            .foregroundColor(fg)
            .cornerRadius(AppTheme.controlRadius)
    }
}

/// Circular icon button on a soft raised disc (notification/gear style)
struct CircleIconButton: View {
    let systemImage: String
    let tint: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body).fontWeight(.medium)
                .foregroundColor(tint)
                .frame(width: 44, height: 44)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }
}

/// Big-metric stat card (icon + caption on top, huge value + unit, footnote below)
struct StatCard: View {
    let icon: String
    let caption: String
    let value: String
    let unit: String
    let footnote: String
    var tint: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption).foregroundColor(.secondary)
                Text(caption).font(.caption).foregroundColor(.secondary)
            }
            .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.brand(30, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(tint)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: value)
                Text(unit)
                    .font(.callout).foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(caption): \(value) \(unit). \(footnote)")
            Text(footnote)
                .font(.caption2).foregroundColor(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 3)
        )
    }
}

/// Progress ring with centered value (hero-metric style)
struct RingGauge: View {
    let fraction: Double // 0...1
    let valueText: String
    let caption: String
    var tint: Color = AppTheme.accent
    var size: CGFloat = 92
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray5), lineWidth: 10)
                .frame(width: size, height: size)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: fraction)
            VStack(spacing: 0) {
                Text(valueText)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.7)
                Text(caption)
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(caption): \(valueText)")
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
