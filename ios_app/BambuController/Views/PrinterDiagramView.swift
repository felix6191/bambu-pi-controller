// PrinterDiagramView.swift - Stylized Bambu Lab A1 with live values at their
// physical positions: nozzle at the toolhead, bed at the heatbed, chamber
// top-right, progress on the printed object. Toolhead + object animate with progress.
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
                // Frame: columns, top bar, feet
                machineFrame(w: w, h: h)
                // Bed + printed object
                bedAndObject(w: w, h: h)
                // X rail + moving toolhead
                toolhead(w: w, h: h)
                // Value pills with connectors
                if let s = status {
                    nozzlePill(s, w: w, h: h)
                    bedPill(s, w: w, h: h)
                    chamberPill(s, w: w, h: h)
                    fanPill(s, w: w, h: h)
                    progressLabel(s, w: w, h: h)
                } else {
                    Text("Keine Daten")
                        .font(.caption).foregroundColor(.secondary)
                        .position(x: w * 0.5, y: h * 0.5)
                }
            }
        }
        .aspectRatio(0.98, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(diagramSummary)
    }

    private var diagramSummary: String {
        guard let s = status else { return "Druckerdiagramm, keine Daten" }
        return "Druckerdiagramm: \(s.state.displayName), Düse \(Int(s.nozzleTemp)) von \(Int(s.nozzleTargetTemp)) Grad, Bett \(Int(s.bedTemp)) von \(Int(s.bedTargetTemp)) Grad, Fortschritt \(Int(s.printJob.progress)) Prozent"
    }

    // MARK: - Machine

    private func machineFrame(w: CGFloat, h: CGFloat) -> some View {
        let metal = Color(.systemGray3)
        return ZStack {
            // columns
            RoundedRectangle(cornerRadius: 4).fill(metal)
                .frame(width: w * 0.055, height: h * 0.90)
                .position(x: w * 0.13, y: h * 0.495)
            RoundedRectangle(cornerRadius: 4).fill(metal)
                .frame(width: w * 0.055, height: h * 0.90)
                .position(x: w * 0.87, y: h * 0.495)
            // top bar
            RoundedRectangle(cornerRadius: 5).fill(metal)
                .frame(width: w * 0.84, height: h * 0.05)
                .position(x: w * 0.5, y: h * 0.065)
            // brand dot
            Circle().fill(AppTheme.accent)
                .frame(width: 7, height: 7)
                .position(x: w * 0.5, y: h * 0.065)
            // feet
            RoundedRectangle(cornerRadius: 3).fill(Color(.systemGray4))
                .frame(width: w * 0.12, height: h * 0.03)
                .position(x: w * 0.13, y: h * 0.955)
            RoundedRectangle(cornerRadius: 3).fill(Color(.systemGray4))
                .frame(width: w * 0.12, height: h * 0.03)
                .position(x: w * 0.87, y: h * 0.955)
            // X rail
            RoundedRectangle(cornerRadius: 3).fill(Color(.systemGray2))
                .frame(width: w * 0.74, height: h * 0.028)
                .position(x: w * 0.5, y: h * 0.28)
        }
    }

    private func bedAndObject(w: CGFloat, h: CGFloat) -> some View {
        let bedTop = h * 0.70
        let objH = CGFloat(progress) * h * 0.30
        return ZStack {
            // bed rails
            RoundedRectangle(cornerRadius: 2).fill(Color(.systemGray4))
                .frame(width: w * 0.56, height: h * 0.018)
                .position(x: w * 0.5, y: h * 0.775)
            // heatbed
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [Color(.systemGray2), Color(.systemGray4)], startPoint: .top, endPoint: .bottom))
                .frame(width: w * 0.60, height: h * 0.045)
                .position(x: w * 0.5, y: bedTop + h * 0.022)
            // printed object grows with progress
            if progress > 0.005 {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [AppTheme.accent, AppTheme.accent.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                    .frame(width: w * 0.30, height: max(objH, 4))
                    .position(x: w * 0.5, y: bedTop - max(objH, 4) / 2)
                    .animation(.easeInOut(duration: 1), value: progress)
            }
        }
    }

    private func toolhead(w: CGFloat, h: CGFloat) -> some View {
        let tx = w * (0.24 + 0.52 * progress)
        let railBottom = h * 0.294
        return ZStack {
            // head box
            RoundedRectangle(cornerRadius: 5).fill(Color(.systemGray))
                .frame(width: w * 0.17, height: h * 0.075)
                .position(x: tx, y: railBottom + h * 0.037)
                .animation(.easeInOut(duration: 1), value: progress)
            // nozzle tip
            Path { p in
                p.move(to: CGPoint(x: tx - w * 0.018, y: railBottom + h * 0.075))
                p.addLine(to: CGPoint(x: tx + w * 0.018, y: railBottom + h * 0.075))
                p.addLine(to: CGPoint(x: tx, y: railBottom + h * 0.105))
                p.closeSubpath()
            }
            .fill(nozzleDot)
            // heat glow when hot
            if let s = status, s.nozzleTemp > 50 {
                Circle().fill(Color.orange.opacity(0.35))
                    .frame(width: 10, height: 10)
                    .position(x: tx, y: railBottom + h * 0.105)
            }
        }
    }

    private var nozzleDot: Color {
        guard let s = status else { return .gray }
        if s.nozzleTargetTemp > 0 && s.nozzleTargetTemp - s.nozzleTemp > 3 { return .orange }
        if s.nozzleTemp > 50 { return AppTheme.accent }
        return .gray
    }

    private func nozzleTip(w: CGFloat, h: CGFloat) -> CGPoint {
        CGPoint(x: w * (0.24 + 0.52 * progress), y: h * 0.294 + h * 0.105)
    }

    // MARK: - Value overlays

    private func nozzlePill(_ s: PrinterStatus, w: CGFloat, h: CGFloat) -> some View {
        let tip = nozzleTip(w: w, h: h)
        let px = w * 0.20, py = h * 0.155
        return ZStack {
            Path { p in
                p.move(to: CGPoint(x: px + w * 0.10, y: py + 12))
                p.addLine(to: CGPoint(x: tip.x, y: tip.y - 4))
            }.stroke(Color.secondary.opacity(0.6), lineWidth: 1)
            Circle().fill(nozzleDot).frame(width: 6, height: 6).position(tip)
            ValuePill(icon: "thermometer.high", text: "\(Int(s.nozzleTemp))° / \(Int(s.nozzleTargetTemp))°", tint: .orange)
                .position(x: px, y: py)
        }
    }

    private func bedPill(_ s: PrinterStatus, w: CGFloat, h: CGFloat) -> some View {
        let ex = w * 0.80, ey = h * 0.722
        let px = w * 0.80, py = h * 0.60
        return ZStack {
            Path { p in
                p.move(to: CGPoint(x: px, y: py + 12))
                p.addLine(to: CGPoint(x: ex, y: ey))
            }.stroke(Color.secondary.opacity(0.6), lineWidth: 1)
            Circle().fill(Color.red).frame(width: 6, height: 6).position(x: ex, y: ey)
            ValuePill(icon: "square.stack.3d.up.fill", text: "\(Int(s.bedTemp))° / \(Int(s.bedTargetTemp))°", tint: .red)
                .position(x: px, y: py)
        }
    }

    private func chamberPill(_ s: PrinterStatus, w: CGFloat, h: CGFloat) -> some View {
        ValuePill(icon: "thermometer.medium", text: "\(Int(s.chamberTemp))°", tint: .purple)
            .position(x: w * 0.80, y: h * 0.155)
    }

    private func fanPill(_ s: PrinterStatus, w: CGFloat, h: CGFloat) -> some View {
        let tx = w * (0.24 + 0.52 * progress)
        return ValuePill(icon: "fanblades.fill", text: "\(s.fanSpeed) %", tint: .blue)
            .position(x: min(tx + w * 0.20, w * 0.82), y: h * 0.40)
    }

    private func progressLabel(_ s: PrinterStatus, w: CGFloat, h: CGFloat) -> some View {
        let objH = CGFloat(progress) * h * 0.30
        let y = max(h * 0.70 - objH - h * 0.075, h * 0.44)
        return VStack(spacing: 1) {
            Text("\(Int(s.printJob.progress)) %")
                .font(.title2).fontWeight(.bold).monospacedDigit()
            if s.printJob.totalLayers > 0 {
                Text("Schicht \(s.printJob.currentLayer)/\(s.printJob.totalLayers)")
                    .font(.caption2).foregroundColor(.secondary).monospacedDigit()
            }
        }
        .position(x: w * 0.5, y: y)
        .animation(.easeInOut(duration: 1), value: progress)
    }
}

private struct ValuePill: View {
    let icon: String
    let text: String
    let tint: Color
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2).foregroundColor(tint)
            Text(text).font(.caption2).fontWeight(.semibold).monospacedDigit()
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
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
