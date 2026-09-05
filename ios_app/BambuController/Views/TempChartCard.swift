// TempChartCard.swift - Live temperature history (Swift Charts, native
// dark-mode + VoiceOver support). Mirrors finance-style line charts:
// smooth nozzle/bed curves with dashed target lines.
import SwiftUI
import Charts

struct TempChartCard: View {
    let history: [TempSample]

    private var domain: ClosedRange<Double> {
        let vals = history.flatMap { [$0.nozzle, $0.bed, $0.nozzleTarget, $0.bedTarget] }
        guard let lo = vals.min(), let hi = vals.max(), hi > lo else { return 0...100 }
        let pad = max((hi - lo) * 0.2, 5)
        return max(0, lo - pad)...(hi + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Temperaturverlauf").font(.headline)
                Spacer()
                HStack(spacing: 10) {
                    LegendDot(color: .orange, label: "Düse")
                    LegendDot(color: .red, label: "Bett")
                }
                .font(.caption2).foregroundColor(.secondary)
            }
            if history.count >= 3 {
                Chart(history) { s in
                    LineMark(x: .value("Zeit", s.date), y: .value("Düse °C", s.nozzle))
                        .foregroundStyle(.orange)
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Zeit", s.date), y: .value("Bett °C", s.bed))
                        .foregroundStyle(.red)
                        .interpolationMethod(.catmullRom)
                    if s.nozzleTarget > 0 {
                        RuleMark(y: .value("Düse Ziel", s.nozzleTarget))
                            .foregroundStyle(.orange.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    if s.bedTarget > 0 {
                        RuleMark(y: .value("Bett Ziel", s.bedTarget))
                            .foregroundStyle(.red.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.hour().minute(), centered: true)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { v in
                        AxisGridLine().foregroundStyle(Color(.systemGray5))
                        AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))°").font(.caption2).foregroundStyle(.secondary) } }
                    }
                }
                .chartYScale(domain: domain)
                .frame(height: 170)
                .animation(.easeInOut(duration: 0.5), value: history.count)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Sammelt Messwerte …")
                        .font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
            }
        }
        .card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chartSummary)
    }

    private var chartSummary: String {
        guard let last = history.last else { return "Temperaturverlauf, noch keine Daten" }
        return "Temperaturverlauf: Düse \(Int(last.nozzle)) Grad, Bett \(Int(last.bed)) Grad, \(history.count) Messwerte"
    }
}

private struct LegendDot: View {
    let color: Color; let label: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
}

#Preview {
    TempChartCard(history: (0..<20).map { i in
        TempSample(date: Date().addingTimeInterval(Double(-19 + i) * 30),
            nozzle: 200 + Double(i) * 0.8, bed: 60 + sin(Double(i)) * 0.5,
            nozzleTarget: 220, bedTarget: 65)
    })
    .padding()
}
