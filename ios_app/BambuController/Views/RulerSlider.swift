// RulerSlider.swift - Playful tick-ruler slider (Solora style):
// big animated value, draggable tick strip, haptic ticks, preset chips.
import SwiftUI
import UIKit

struct RulerSlider: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String
    var tint: Color = .primary
    var presets: [Int] = []

    @State private var dragStart: Int? = nil
    private let selectHaptic = UISelectionFeedbackGenerator()

    private var ppu: CGFloat { 9 } // points per unit

    var body: some View {
        VStack(spacing: 10) {
            // Big live value with numeric transition + subtle pop
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)")
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(value)))
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: value)
                Text(unit)
                    .font(.title3).foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Wert: \(value) \(unit)")

            // Tick strip
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    // ticks
                    ForEach(visibleTicks(width: w), id: \.self) { t in
                        let x = w / 2 + CGFloat(t - value) * ppu
                        RoundedRectangle(cornerRadius: 1)
                            .fill(tickColor(t))
                            .frame(width: t % 10 == 0 ? 3 : 1.5,
                                   height: tickHeight(t, full: h))
                            .position(x: x, y: h * 0.42)
                    }
                    // center marker
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary)
                        .frame(width: 3.5, height: h * 0.72)
                        .position(x: w / 2, y: h * 0.42)
                    // edge fade
                    HStack {
                        LinearGradient(colors: [.white.opacity(0.001), .clear], startPoint: .leading, endPoint: .trailing)
                        Spacer()
                        LinearGradient(colors: [.clear, .white.opacity(0.001)], startPoint: .leading, endPoint: .trailing)
                    }
                }
                .frame(width: w, height: h)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            if dragStart == nil { dragStart = value; selectHaptic.prepare() }
                            let raw = (dragStart ?? value) + Int(-g.translation.width / ppu)
                            let snapped = clamp((raw / step) * step)
                            if snapped != value {
                                value = snapped
                                selectHaptic.selectionChanged()
                            }
                        }
                        .onEnded { _ in
                            dragStart = nil
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                )
                .accessibilityLabel("Regler")
                .accessibilityAdjustableAction { dir in
                    switch dir {
                    case .increment: value = clamp(value + step)
                    case .decrement: value = clamp(value - step)
                    @unknown default: break
                    }
                }
            }
            .frame(height: 92)

            // range captions
            HStack {
                Text("\(range.lowerBound)\(unit)").font(.caption2).foregroundColor(.secondary)
                Spacer()
                Text("max. \(range.upperBound)\(unit)").font(.caption2).foregroundColor(.secondary)
            }

            // preset chips
            if !presets.isEmpty {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { p in
                        Button("\(p)°") {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { value = clamp(p) }
                            selectHaptic.selectionChanged()
                        }
                        .font(.subheadline).fontWeight(value == p ? .semibold : .regular)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(value == p ? tint : Color(.systemGray5))
                        .foregroundColor(value == p ? .white : .primary)
                        .cornerRadius(10)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func clamp(_ v: Int) -> Int {
        min(max(range.lowerBound, v), range.upperBound)
    }

    private func visibleTicks(width w: CGFloat) -> [Int] {
        let span = Int(w / ppu) + 4
        let lo = max(range.lowerBound, value - span)
        let hi = min(range.upperBound, value + span)
        guard lo <= hi else { return [] }
        return Array(lo...hi)
    }

    private func tickHeight(_ t: Int, full h: CGFloat) -> CGFloat {
        if t % 50 == 0 { return h * 0.52 }
        if t % 10 == 0 { return h * 0.40 }
        return h * 0.24
    }

    private func tickColor(_ t: Int) -> Color {
        if t <= value { return tint.opacity(t % 10 == 0 ? 1 : 0.55) }
        return Color(.systemGray3)
    }
}

#Preview {
    @Previewable @State var v = 210
    return VStack {
        RulerSlider(value: $v, range: 0...300, step: 5, unit: "°C", tint: .orange, presets: [190, 210, 230])
            .padding()
    }
}
