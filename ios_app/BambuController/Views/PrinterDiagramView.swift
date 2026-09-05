// PrinterDiagramView.swift - Hero image of the Bambu A1 on a dark stage so the
// white render pops in light + dark mode. Live values sit at their physical
// positions; the static stage renders cheap, only the overlay reacts to ticks.
import SwiftUI

struct PrinterDiagramView: View {
    let status: PrinterStatus?

    private var progress: Double {
        guard let s = status else { return 0 }
        return min(max(s.printJob.progress / 100, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                PrinterStage(glow: glowColor)

                if let s = status {
                    overlay(s, w: w, h: h)
                } else {
                    VStack(spacing: 6) {
                        ProgressView().tint(.white)
                        Text("Verbinde …")
                            .font(.brand(13))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .position(x: w * 0.5, y: h * 0.45)
                }
            }
        }
        .aspectRatio(1.05, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(diagramSummary)
    }

    private var glowColor: Color {
        guard let s = status else { return .gray }
        switch s.state {
        case .printing: return AppTheme.accent
        case .paused: return .orange
        default: return .gray
        }
    }

    private var diagramSummary: String {
        guard let s = status else { return "Druckerbild, keine Daten" }
        return "Drucker: \(s.state.displayName), Düse \(Int(s.nozzleTemp)) von \(Int(s.nozzleTargetTemp)) Grad, Bett \(Int(s.bedTemp)) von \(Int(s.bedTargetTemp)) Grad, Fortschritt \(Int(s.printJob.progress)) Prozent"
    }

    // MARK: - Anchors on the rendered printer (fractions of the image frame)

    private func nozzleAnchor(w: CGFloat, h: CGFloat) -> CGPoint { CGPoint(x: w * 0.545, y: h * 0.395) }
    private func bedAnchor(w: CGFloat, h: CGFloat) -> CGPoint { CGPoint(x: w * 0.46, y: h * 0.79) }

    // MARK: - Live overlay (only this part reacts to status ticks)

    @ViewBuilder
    private func overlay(_ s: PrinterStatus, w: CGFloat, h: CGFloat) -> some View {
        nozzlePill(s, w: w, h: h)
        bedPill(s, w: w, h: h)
        chamberPill(s, w: w, h: h)
        progressBadge(s, w: w, h: h)
    }

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
                  tint: .cyan)
            .position(x: w * 0.82, y: h * 0.12)
    }

    private func progressBadge(_ s: PrinterStatus, w: CGFloat, h: CGFloat) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 5).frame(width: 64, height: 64)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.8), value: progress)
                Text("\(Int(s.printJob.progress))")
                    .font(.brand(20, weight: .bold))
                    .foregroundColor(.white)
                    .monospacedDigit()
            }
            if s.printJob.totalLayers > 0 {
                Text("\(s.printJob.currentLayer)/\(s.printJob.totalLayers) Layer")
                    .font(.brand(11))
                    .foregroundColor(.white.opacity(0.7))
                    .monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
        }
        .position(x: w * 0.18, y: h * 0.72)
    }

    // MARK: - Connectors

    private func connector(from: CGPoint, to: CGPoint) -> some View {
        Path { p in
            p.move(to: from)
            p.addLine(to: to)
        }
        .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        .foregroundColor(.white.opacity(0.35))
    }

    private func anchorDot(at point: CGPoint, hot: Bool) -> some View {
        Circle()
            .fill(hot ? Color.orange : Color.white.opacity(0.4))
            .frame(width: hot ? 8 : 6, height: hot ? 8 : 6)
            .shadow(color: hot ? .orange : .clear, radius: 4)
            .position(point)
    }
}

// MARK: - Static stage (dark backdrop + printer render, renders once)

private struct PrinterStage: View {
    let glow: Color

    var body: some View {
        ZStack {
            // dark stage so the white render is visible in both color schemes
            LinearGradient(
                colors: [Color(white: 0.13), Color(white: 0.07)],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [glow.opacity(0.35), .clear],
                center: .center, startRadius: 10, endRadius: 240
            )
            .animation(.easeOut(duration: 0.6), value: glow == AppTheme.accent)

            Image("printer-hero")
                .resizable()
                .scaledToFit()
                .padding(10)
        }
        .animation(.easeInOut(duration: 0.6), value: glow)
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
                Text(title).font(.brand(9)).foregroundColor(.white.opacity(0.6))
                Text(text)
                    .font(.brand(12, weight: .bold))
                    .foregroundColor(.white)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}

#Preview("Diagramm") {
    PrinterDiagramView(status: DemoService.shared.status)
        .padding()
}
