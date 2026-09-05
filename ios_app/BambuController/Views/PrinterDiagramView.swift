// PrinterDiagramView.swift - Hero image of the Bambu A1 with live values
// overlaid at their physical positions: nozzle temp at the toolhead,
// bed temp at the base plate, chamber/ambient top-right, progress ring on top.
import SwiftUI

struct PrinterDiagramView: View {
    let status: PrinterStatus?

    private var progress: Double {
        guard let s = status else { return 0 }
        return min(max(s.printJob.progress / 100, 0), 1)
    }

    /// Accent glow matching the current machine state (calm when idle)
    private var glowColor: Color {
        guard let s = status else { return .gray }
        switch s.state {
        case .printing: return AppTheme.accent
        case .paused: return .orange
        default: return .gray
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // soft status-colored aurora behind the printer
                RadialGradient(
                    colors: [glowColor.opacity(status == nil ? 0.08 : 0.22), .clear],
                    center: .center, startRadius: h * 0.05, endRadius: h * 0.55
                )
                .scaleEffect(status?.state == .printing ? 1.04 : 1.0)
                .animation(.easeInOut(duration: 1.2), value: status?.state)

                Image("printer-hero")
                    .resizable()
                    .scaledToFit()
                    .frame(width: w, height: h)
                    .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 8)

                if let s = status {
                    chamberPill(s, w: w, h: h)
                    nozzlePill(s, w: w, h: h)
                    bedPill(s, w: w, h: h)
                    progressBadge(s, w: w, h: h)
                } else {
                    VStack(spacing: 6) {
                        ProgressView()
                        Text("Verbinde …")
                            .font(.brand(13))
                            .foregroundColor(.secondary)
                    }
                    .position(x: w * 0.5, y: h * 0.45)
                }
            }
        }
        .aspectRatio(1.05, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(diagramSummary)
    }

    private var diagramSummary: String {
        guard let s = status else { return "Druckerbild, keine Daten" }
        return "Drucker: \(s.state.displayName), Düse \(Int(s.nozzleTemp)) von \(Int(s.nozzleTargetTemp)) Grad, Bett \(Int(s.bedTemp)) von \(Int(s.bedTargetTemp)) Grad, Fortschritt \(Int(s.printJob.progress)) Prozent"
    }

    // MARK: - Anchors on the rendered printer (fractions of the image frame)

    private func nozzleAnchor(w: CGFloat, h: CGFloat) -> CGPoint { CGPoint(x: w * 0.545, y: h * 0.395) }
    private func bedAnchor(w: CGFloat, h: CGFloat) -> CGPoint { CGPoint(x: w * 0.46, y: h * 0.79) }

    // MARK: - Overlays

    private func nozzlePill(_ s: PrinterStatus, w: CGFloat, h: CGFloat) -> some View {
        let target = nozzleAnchor(w: w, h: h)
        let px = w * 0.165, py = h * 0.28
        return ZStack {
            connector(from: CGPoint(x: px + w * 0.10, y: py + 14), to: target)
            anchorDot(at: target, hot: s.nozzleTemp > 50)
            ValuePill(icon: "thermometer.high",
                      title: "Düse",
                      text: "\(Int(s.nozzleTemp))° / \(Int(s.nozzleTargetTemp))°",
                      tint: .orange)
                .position(x: px, y: py)
        }
    }

    private func bedPill(_ s: PrinterStatus, w: CGFloat, h: CGFloat) -> some View {
        let target = bedAnchor(w: w, h: h)
        let px = w * 0.82, py = h * 0.60
        return ZStack {
            connector(from: CGPoint(x: px - w * 0.11, y: py + 14), to: target)
            anchorDot(at: target, hot: s.bedTemp > 40)
            ValuePill(icon: "square.stack.3d.up.fill",
                      title: "Bett",
                      text: "\(Int(s.bedTemp))° / \(Int(s.bedTargetTemp))°",
                      tint: .red)
                .position(x: px, y: py)
        }
    }

    private func chamberPill(_ s: PrinterStatus, w: CGFloat, h: CGFloat) -> some View {
        ValuePill(icon: "thermometer.medium",
                  title: "Raum",
                  text: "\(Int(s.chamberTemp))°",
                  tint: .blue)
            .position(x: w * 0.82, y: h * 0.12)
    }

    private func progressBadge(_ s: PrinterStatus, w: CGFloat, h: CGFloat) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color(.systemGray4), lineWidth: 5).frame(width: 64, height: 64)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.8), value: progress)
                Text("\(Int(s.printJob.progress))")
                    .font(.brand(20, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .background(Circle().fill(.ultraThinMaterial))
            if s.printJob.totalLayers > 0 {
                Text("\(s.printJob.currentLayer)/\(s.printJob.totalLayers) Layer")
                    .font(.brand(11))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .position(x: w * 0.18, y: h * 0.72)
    }

    // MARK: - Connector drawing

    private func connector(from: CGPoint, to: CGPoint) -> some View {
        Path { p in
            p.move(to: from)
            p.addLine(to: to)
        }
        .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        .foregroundColor(.secondary.opacity(0.55))
    }

    private func anchorDot(at point: CGPoint, hot: Bool) -> some View {
        ZStack {
            if hot {
                Circle().fill(Color.orange.opacity(0.30))
                    .frame(width: 16, height: 16)
                    .phaseAnimator([0.6, 1.0]) { view, phase in view.scaleEffect(phase) } animation: { _ in
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                    }
            }
            Circle().fill(hot ? Color.orange : Color(.systemGray3))
                .frame(width: 6, height: 6)
        }
        .position(point)
    }
}

private struct ValuePill: View {
    let icon: String
    let title: String
    let text: String
    let tint: Color
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2).foregroundColor(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.brand(9)).foregroundColor(.secondary)
                Text(text).font(.brand(12, weight: .bold)).monospacedDigit()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }
}

#Preview("Diagramm hell") {
    PrinterDiagramView(status: DemoService.shared.status)
        .padding()
}

#Preview("Diagramm dunkel") {
    PrinterDiagramView(status: DemoService.shared.status)
        .padding()
        .preferredColorScheme(.dark)
}
