// ControlsView.swift - Manual printer controls
import SwiftUI

struct ControlsView: View {
    @StateObject private var vm = PrinterViewModel.shared
    @State private var nozzle = 200
    @State private var bed = 60
    @State private var speed = 100
    @State private var flow = 100

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    TemperatureControlSection(title: "Düse", current: vm.status?.nozzleTemp ?? 0, target: $nozzle, max: 300, color: .orange) { Task { await vm.setNozzleTemperature($0) } }
                    TemperatureControlSection(title: "Druckbett", current: vm.status?.bedTemp ?? 0, target: $bed, max: 120, color: .red) { Task { await vm.setBedTemperature($0) } }
                    SliderControlSection(title: "Druckgeschwindigkeit", value: $speed, range: 50...200, step: 5, unit: "%", current: vm.status?.printSpeed ?? 100, color: .blue) { Task { await vm.setPrintSpeed($0) } }
                    SliderControlSection(title: "Flow Rate", value: $flow, range: 50...150, step: 5, unit: "%", current: vm.status?.flowRate ?? 100, color: .purple) { Task { await vm.setFlowRate($0) } }
                    if let s = vm.status { FanSpeedView(speed: s.fanSpeed) }
                    Spacer(minLength: 100)
                }.padding()
            }
            .navigationTitle("Steuerung")
            .onChange(of: vm.status?.nozzleTargetTemp) { nozzle = Int($0 ?? 0) }
            .onChange(of: vm.status?.bedTargetTemp) { bed = Int($0 ?? 0) }
            .onChange(of: vm.status?.printSpeed) { speed = $0 ?? 100 }
            .onChange(of: vm.status?.flowRate) { flow = $0 ?? 100 }
        }
    }
}

struct TemperatureControlSection: View {
    let title: String; let current: Double; @Binding var target: Int; let max: Int; let color: Color; let onSet: (Int) -> Void
    private var presets: [Int] { title == "Düse" ? [0,190,210,230,250] : [0,50,60,70,80,100] }

    var body: some View {
        VStack(spacing: 12) {
            HStack { Text(title).font(.headline); Spacer(); Text("\(Int(current))° / \(target)°").font(.system(.body, design: .rounded)).fontWeight(.medium).foregroundColor(color) }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray5)).frame(height: 20)
                    RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: [color.opacity(0.5), color], startPoint: .leading, endPoint: .trailing)).frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(current) / CGFloat(max))), height: 20).animation(.easeInOut(duration: 0.3), value: current)
                    if target > 0 { Rectangle().fill(Color.white).frame(width: 2, height: 24).offset(x: min(geo.size.width, geo.size.width * CGFloat(target) / CGFloat(max)) - 1) }
                }
            }.frame(height: 20)
            Slider(value: Binding(get: { Double(target) }, set: { target = Int($0) }), in: 0...Double(max), step: 1).tint(color)
            HStack(spacing: 8) { ForEach(presets, id: \.self) { t in Button("\(t)°") { target = t; onSet(t) }.font(.caption).padding(.horizontal, 12).padding(.vertical, 6).background(target == t ? color : Color(.systemGray5)).foregroundColor(target == t ? .white : .primary).cornerRadius(8) }; Spacer() }
        }.padding().background(Color(.secondarySystemGroupedBackground)).cornerRadius(16)
    }
}

struct SliderControlSection: View {
    let title: String; @Binding var value: Int; let range: ClosedRange<Int>; let step: Int; let unit: String; let current: Int; let color: Color; let onSet: (Int) -> Void
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text(title).font(.headline); Spacer(); Text("\(value)\(unit)").font(.system(.body, design: .rounded)).fontWeight(.bold).foregroundColor(color) }
            Slider(value: Binding(get: { Double(value) }, set: { value = Int($0) }), in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step)).tint(color)
            HStack { Text("\(range.lowerBound)\(unit)").font(.caption).foregroundColor(.secondary); Spacer(); Text("Aktuell: \(current)\(unit)").font(.caption).foregroundColor(.secondary); Spacer(); Text("\(range.upperBound)\(unit)").font(.caption).foregroundColor(.secondary) }
            Button("Anwenden") { onSet(value) }.buttonStyle(.borderedProminent).tint(color).frame(maxWidth: .infinity)
        }.padding().background(Color(.secondarySystemGroupedBackground)).cornerRadius(16)
    }
}

struct FanSpeedView: View {
    let speed: Int
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("Lüfter").font(.headline); Spacer(); Text("\(speed)%").font(.system(.body, design: .rounded)).fontWeight(.medium) }
            HStack(spacing: 4) { ForEach(0..<10, id: \.self) { i in RoundedRectangle(cornerRadius: 2).fill(i < speed/10 ? Color.blue : Color(.systemGray5)).frame(height: 20).animation(.easeInOut(duration: 0.3), value: speed) } }
        }.padding().background(Color(.secondarySystemGroupedBackground)).cornerRadius(16)
    }
}

#Preview("Controls") { ControlsView() }