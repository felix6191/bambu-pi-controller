// ControlsView.swift - Manual printer controls (limit-aware: values are clamped to printer caps before sending)
import SwiftUI

struct ControlsView: View {
    @ObservedObject private var vm = PrinterViewModel.shared
    @State private var nozzle = 200
    @State private var bed = 60
    @State private var speed = 100
    @State private var flow = 100

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    nozzleSection
                    bedSection
                    speedSection
                    flowSection
                    if let s = vm.status { FanSpeedView(speed: s.fanSpeed) }
                    LimitHintCard(limits: vm.limits)
                    Spacer(minLength: 100)
                }.padding()
            }
            .navigationTitle("Steuerung")
            .onChange(of: vm.status?.nozzleTargetTemp) { nozzle = vm.clampedNozzle(Int($0 ?? 0)) }
            .onChange(of: vm.status?.bedTargetTemp) { bed = vm.clampedBed(Int($0 ?? 0)) }
            .onChange(of: vm.status?.printSpeed) { speed = vm.clampedSpeed($0 ?? 100) }
            .onChange(of: vm.status?.flowRate) { flow = vm.clampedFlow($0 ?? 100) }
        }
    }

    private var nozzleSection: some View {
        TemperatureControlSection(
            title: "Düse",
            current: vm.status?.nozzleTemp ?? 0,
            target: $nozzle,
            maxTemp: vm.limits.maxNozzleTemp,
            color: .orange,
            onSet: { temp in Task { await vm.setNozzleTemperature(temp) } }
        )
    }

    private var bedSection: some View {
        TemperatureControlSection(
            title: "Druckbett",
            current: vm.status?.bedTemp ?? 0,
            target: $bed,
            maxTemp: vm.limits.maxBedTemp,
            color: .red,
            onSet: { temp in Task { await vm.setBedTemperature(temp) } }
        )
    }

    private var speedSection: some View {
        SliderControlSection(
            title: "Druckgeschwindigkeit",
            value: $speed,
            range: vm.limits.minSpeed...vm.limits.maxSpeed,
            step: 5,
            unit: "%",
            current: vm.status?.printSpeed ?? 100,
            color: .blue,
            onSet: { spd in Task { await vm.setPrintSpeed(spd) } }
        )
    }

    private var flowSection: some View {
        SliderControlSection(
            title: "Flow Rate",
            value: $flow,
            range: vm.limits.minFlow...vm.limits.maxFlow,
            step: 5,
            unit: "%",
            current: vm.status?.flowRate ?? 100,
            color: .purple,
            onSet: { flw in Task { await vm.setFlowRate(flw) } }
        )
    }
}

struct LimitHintCard: View {
    let limits: PrinterLimits
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.checkmark.fill").foregroundColor(.green)
            Text("Limits aktiv: Düse max. \(limits.maxNozzleTemp)°, Bett max. \(limits.maxBedTemp)°, Speed \(limits.minSpeed)–\(limits.maxSpeed)%, Flow \(limits.minFlow)–\(limits.maxFlow)%. Höhere Werte werden automatisch gekappt.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
}

struct TemperatureControlSection: View {
    let title: String
    let current: Double
    @Binding var target: Int
    let maxTemp: Int
    let color: Color
    let onSet: (Int) -> Void

    private var presets: [Int] { title == "Düse" ? [0,190,210,230,Swift.min(250, maxTemp)] : [0,50,60,70,80,Swift.min(100, maxTemp)] }
    private var clamped: Int { Swift.min(Swift.max(0, target), maxTemp) }
    private var wasClamped: Bool { target != clamped }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(Int(current))° / \(target)°")
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.medium)
                    .foregroundColor(color)
                    .monospacedDigit()
            }
            Text("Max. \(maxTemp)° (Druckerlimit)").font(.caption2).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
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
            Slider(value: Binding(get: { Double(target) }, set: { target = Swift.min(Swift.max(0, Int($0)), maxTemp) }), in: 0...Double(maxTemp), step: 1).tint(color)
            if wasClamped {
                Text("Auf Druckerlimit gekappt: \(clamped)°").font(.caption2).foregroundColor(.orange)
            }
            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { t in
                    Button("\(t)°") { target = t; onSet(t) }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(target == t ? color : Color(.systemGray5))
                        .foregroundColor(target == t ? .white : .primary)
                        .cornerRadius(8)
                }
                Spacer()
            }
        }.padding().background(Color(.secondarySystemGroupedBackground)).cornerRadius(16)
    }
}

struct SliderControlSection: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String
    let current: Int
    let color: Color
    let onSet: (Int) -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(value)\(unit)").font(.system(.body, design: .rounded)).fontWeight(.bold).foregroundColor(color).monospacedDigit()
            }
            Slider(value: Binding(get: { Double(value) }, set: { value = Swift.min(Swift.max(range.lowerBound, Int($0)), range.upperBound) }), in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step)).tint(color)
            HStack {
                Text("\(range.lowerBound)\(unit)").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text("Aktuell: \(current)\(unit)").font(.caption).foregroundColor(.secondary).monospacedDigit()
                Spacer()
                Text("\(range.upperBound)\(unit)").font(.caption).foregroundColor(.secondary)
            }
            Button("Anwenden") { onSet(value) }.buttonStyle(.borderedProminent).tint(color).frame(maxWidth: .infinity)
        }.padding().background(Color(.secondarySystemGroupedBackground)).cornerRadius(16)
    }
}

struct FanSpeedView: View {
    let speed: Int
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("Lüfter").font(.headline); Spacer(); Text("\(speed)%").font(.system(.body, design: .rounded)).fontWeight(.medium).monospacedDigit() }
            HStack(spacing: 4) { ForEach(0..<10, id: \.self) { i in RoundedRectangle(cornerRadius: 2).fill(i < speed/10 ? Color.blue : Color(.systemGray5)).frame(height: 20).animation(.easeInOut(duration: 0.3), value: speed) } }
        }.padding().background(Color(.secondarySystemGroupedBackground)).cornerRadius(16)
    }
}

#Preview("Controls") { ControlsView() }
