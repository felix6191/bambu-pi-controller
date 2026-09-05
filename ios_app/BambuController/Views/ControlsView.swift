// ControlsView.swift - Manual printer controls (limit-aware, official Bambu presets)
import SwiftUI

struct ControlsView: View {
    @ObservedObject private var vm = PrinterViewModel.shared
    @State private var nozzle = 200
    @State private var bed = 60
    @State private var flow = 100
    @State private var lightOn: Bool?

    var body: some View {
        NavigationStack {
            ScrollView { formContent }
            .navigationTitle("Steuerung")
        }
    }

    private var formContent: some View {
        VStack(spacing: 16) {
            if let fb = vm.feedback { FeedbackBanner(feedback: fb) }
            nozzleSection
            bedSection
            speedSection
            flowSection
            fanSection
            lightSection
            LimitHintCard(limits: vm.limits)
            Spacer(minLength: 90)
        }
        .padding()
        .onChange(of: vm.status?.nozzleTargetTemp) { _, v in nozzle = vm.clampedNozzle(Int(v ?? 0)) }
        .onChange(of: vm.status?.bedTargetTemp) { _, v in bed = vm.clampedBed(Int(v ?? 0)) }
        .onChange(of: vm.status?.flowRate) { _, v in flow = vm.clampedFlow(v ?? 100) }
        .onChange(of: vm.status?.chamberLight) { _, v in lightOn = (v == "on") }
    }

    // MARK: - Sections

    private var nozzleSection: some View {
        TemperatureControlSection(
            title: "Düse", subtitle: "Hotend · max. \(vm.limits.maxNozzleTemp) °C",
            current: vm.status?.nozzleTemp ?? 0,
            target: $nozzle,
            maxTemp: vm.limits.maxNozzleTemp,
            color: .orange,
            presets: [0, 190, 210, 230, 250],
            busy: vm.pending.contains("nozzle"),
            onSet: { temp in Task { await vm.setNozzleTemperature(temp) } }
        )
    }

    private var bedSection: some View {
        TemperatureControlSection(
            title: "Druckbett", subtitle: "Heatbed · max. \(vm.limits.maxBedTemp) °C",
            current: vm.status?.bedTemp ?? 0,
            target: $bed,
            maxTemp: vm.limits.maxBedTemp,
            color: .red,
            presets: [0, 50, 60, 65, 80, 100],
            busy: vm.pending.contains("bed"),
            onSet: { temp in Task { await vm.setBedTemperature(temp) } }
        )
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Druckgeschwindigkeit").font(.headline)
                    Text("Offizielle Bambu-Modi").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if vm.pending.contains("speed") { ProgressView() }
                if let lvl = SpeedPreset.all.first(where: { $0.id == (vm.status?.speedLevel ?? 2) }) {
                    Pill(text: "\(lvl.name) · \(lvl.percent) %", color: .blue)
                }
            }
            ForEach(SpeedPreset.all) { preset in
                SpeedRow(
                    preset: preset,
                    active: (vm.status?.speedLevel ?? 2) == preset.id
                ) { Task { await vm.setSpeedLevel(preset.id) } }
            }
        }.card()
    }

    private var flowSection: some View {
        SliderControlSection(
            title: "Flow Rate", subtitle: "Materialfluss · 50–150 %",
            value: $flow,
            range: vm.limits.minFlow...vm.limits.maxFlow,
            step: 5, unit: "%",
            current: vm.status?.flowRate ?? 100,
            color: .purple,
            busy: vm.pending.contains("flow"),
            onSet: { flw in Task { await vm.setFlowRate(flw) } }
        )
    }

    private var fanSection: some View {
        VStack(spacing: 10) {
            HStack { Text("Lüfter").font(.headline); Spacer() }
            FanRow(label: "Bauteil", speed: vm.status?.fanSpeed ?? 0, color: .blue)
            FanRow(label: "Aux", speed: vm.status?.auxFanSpeed ?? 0, color: .cyan)
        }.card()
    }

    private var lightSection: some View {
        HStack {
            Label("Bauraumlicht", systemImage: "lightbulb.fill")
                .font(.headline)
            Spacer()
            Toggle("", isOn: Binding(
                get: { lightOn ?? (vm.status?.chamberLight == "on") },
                set: { v in lightOn = v; Task { await vm.setLight(on: v) } }
            ))
            .tint(AppTheme.accent)
        }.card()
    }
}

// MARK: - Rows & sections

private struct SpeedRow: View {
    let preset: SpeedPreset
    let active: Bool
    let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.body).fontWeight(active ? .semibold : .regular)
                    Text("\(preset.percent) % · \(preset.blurb)").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if active { Image(systemName: "checkmark.circle.fill").foregroundColor(AppTheme.accent) }
            }
            .padding(10)
            .background(active ? AppTheme.accent.opacity(0.12) : Color(.systemGray5).opacity(0.5))
            .cornerRadius(10)
        }.buttonStyle(.plain)
    }
}

struct LimitHintCard: View {
    let limits: PrinterLimits
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.checkmark.fill").foregroundColor(AppTheme.accent)
            Text("Limits aktiv (Bambu Lab A1, offiziell): Düse max. \(limits.maxNozzleTemp) °C, Bett max. \(limits.maxBedTemp) °C. Höhere Werte werden automatisch gekappt.")
                .font(.caption).foregroundColor(.secondary)
        }.card()
    }
}

struct TemperatureControlSection: View {
    let title: String
    var subtitle: String = ""
    let current: Double
    @Binding var target: Int
    let maxTemp: Int
    let color: Color
    var presets: [Int] = []
    var busy: Bool = false
    let onSet: (Int) -> Void

    private var clamped: Int { Swift.min(Swift.max(0, target), maxTemp) }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundColor(.secondary) }
                }
                Spacer()
                Text("\(Int(current))° / \(target)°")
                    .font(.system(.body, design: .rounded)).fontWeight(.medium).foregroundColor(color).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray5)).frame(height: 20)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: [color.opacity(0.5), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: Swift.max(0, Swift.min(geo.size.width, geo.size.width * CGFloat(current) / CGFloat(Swift.max(1, maxTemp)))), height: 20)
                        .animation(.easeInOut(duration: 0.3), value: current)
                    if target > 0 {
                        Rectangle().fill(Color.white).frame(width: 2, height: 24)
                            .offset(x: Swift.min(geo.size.width, geo.size.width * CGFloat(clamped) / CGFloat(Swift.max(1, maxTemp))) - 1)
                    }
                }
            }.frame(height: 20)
            Slider(value: Binding(get: { Double(target) }, set: { target = Swift.min(Swift.max(0, Int($0)), maxTemp) }), in: 0...Double(maxTemp), step: 1)
                .tint(color)
                .accessibilityLabel("\(title) Zieltemperatur")
                .accessibilityValue("\(target) Grad von maximal \(maxTemp) Grad")
            if !presets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presets.filter { $0 <= maxTemp }, id: \.self) { t in
                            Button("\(t)°") { target = t; onSet(t) }
                                .font(.caption)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(target == t ? color : Color(.systemGray5))
                                .foregroundColor(target == t ? .white : .primary)
                                .cornerRadius(8)
                        }
                    }
                }
            }
            Button { onSet(clamped) } label: {
                if busy { ProgressView().frame(maxWidth: .infinity) }
                else { Text(busy ? "Wird geprüft…" : "Übernehmen").frame(maxWidth: .infinity) }
            }
            .buttonStyle(PrimaryButtonStyle(color: color))
            .disabled(busy)
        }.card()
    }
}

struct SliderControlSection: View {
    let title: String
    var subtitle: String = ""
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String
    let current: Int
    let color: Color
    var busy: Bool = false
    let onSet: (Int) -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundColor(.secondary) }
                }
                Spacer()
                if busy { ProgressView() }
                Text("\(value)\(unit)").font(.system(.body, design: .rounded)).fontWeight(.bold).foregroundColor(color).monospacedDigit()
            }
            Slider(value: Binding(get: { Double(value) }, set: { value = Swift.min(Swift.max(range.lowerBound, Int($0)), range.upperBound) }), in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step))
                .tint(color)
                .accessibilityLabel(title)
                .accessibilityValue("\(value) \(unit)")
            HStack {
                Text("\(range.lowerBound)\(unit)").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text("Aktuell: \(current)\(unit)").font(.caption).foregroundColor(.secondary).monospacedDigit()
                Spacer()
                Text("\(range.upperBound)\(unit)").font(.caption).foregroundColor(.secondary)
            }
            Button { onSet(value) } label: {
                if busy { ProgressView().frame(maxWidth: .infinity) }
                else { Text("Anwenden").frame(maxWidth: .infinity) }
            }
            .buttonStyle(PrimaryButtonStyle(color: color))
            .disabled(busy)
        }.card()
    }
}

private struct FanRow: View {
    let label: String; let speed: Int; let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(label).font(.subheadline); Spacer(); Text("\(speed) %").font(.subheadline).monospacedDigit().foregroundColor(.secondary) }
            HStack(spacing: 4) { ForEach(0..<10, id: \.self) { i in RoundedRectangle(cornerRadius: 2).fill(i < speed/10 ? color : Color(.systemGray5)).frame(height: 14).animation(.easeInOut(duration: 0.3), value: speed) } }
        }
    }
}

#Preview("Controls") { ControlsView() }
