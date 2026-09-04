//  ControlsView.swift
//  BambuController
//
//  Manual printer controls

import SwiftUI

struct ControlsView: View {
    @StateObject private var printerVM = PrinterViewModel.shared
    @State private var nozzleTemp = 200
    @State private var bedTemp = 60
    @State private var printSpeed = 100
    @State private var flowRate = 100
    @State private var showNozzleSlider = false
    @State private var showBedSlider = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Nozzle Temperature
                    TemperatureControlSection(
                        title: "Düse",
                        currentTemp: printerVM.status?.nozzleTemp ?? 0,
                        targetTemp: $nozzleTemp,
                        maxTemp: 300,
                        color: .orange,
                        onSet: { temp in
                            Task { await printerVM.setNozzleTemperature(temp) }
                        }
                    )

                    // Bed Temperature
                    TemperatureControlSection(
                        title: "Druckbett",
                        currentTemp: printerVM.status?.bedTemp ?? 0,
                        targetTemp: $bedTemp,
                        maxTemp: 120,
                        color: .red,
                        onSet: { temp in
                            Task { await printerVM.setBedTemperature(temp) }
                        }
                    )

                    // Print Speed
                    SliderControlSection(
                        title: "Druckgeschwindigkeit",
                        value: $printSpeed,
                        range: 50...200,
                        step: 5,
                        unit: "%",
                        currentValue: printerVM.status?.printSpeed ?? 100,
                        color: .blue,
                        onSet: { value in
                            Task { await printerVM.setPrintSpeed(value) }
                        }
                    )

                    // Flow Rate
                    SliderControlSection(
                        title: "Flow Rate",
                        value: $flowRate,
                        range: 50...150,
                        step: 5,
                        unit: "%",
                        currentValue: printerVM.status?.flowRate ?? 100,
                        color: .purple,
                        onSet: { value in
                            Task { await printerVM.setFlowRate(value) }
                        }
                    )

                    // Fan Speed (read-only for now)
                    if let status = printerVM.status {
                        FanSpeedView(speed: status.fanSpeed)
                    }

                    Spacer(minLength: 100)
                }
                .padding()
            }
            .navigationTitle("Steuerung")
            .onChange(of: printerVM.status?.nozzleTargetTemp) { newValue in
                if let temp = newValue { nozzleTemp = Int(temp) }
            }
            .onChange(of: printerVM.status?.bedTargetTemp) { newValue in
                if let temp = newValue { bedTemp = Int(temp) }
            }
            .onChange(of: printerVM.status?.printSpeed) { newValue in
                if let speed = newValue { printSpeed = speed }
            }
            .onChange(of: printerVM.status?.flowRate) { newValue in
                if let flow = newValue { flowRate = flow }
            }
        }
    }
}

// MARK: - Subviews

struct TemperatureControlSection: View {
    let title: String
    let currentTemp: Double
    @Binding var targetTemp: Int
    let maxTemp: Int
    let color: Color
    let onSet: (Int) -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(Int(currentTemp))° / \(targetTemp)°")
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.medium)
                    .foregroundColor(color)
            }

            // Visual temperature bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray5))
                        .frame(height: 20)

                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.5), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, min(geometry.size.width, geometry.size.width * CGFloat(currentTemp) / CGFloat(maxTemp))), height: 20)
                        .animation(.easeInOut(duration: 0.3), value: currentTemp)

                    // Target indicator
                    if targetTemp > 0 {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2, height: 24)
                            .offset(x: min(geometry.size.width, geometry.size.width * CGFloat(targetTemp) / CGFloat(maxTemp)) - 1)
                    }
                }
            }
            .frame(height: 20)

            // Slider
            Slider(value: Binding(
                get: { Double(targetTemp) },
                set: { targetTemp = Int($0) }
            ), in: 0...Double(maxTemp), step: 1)
            .tint(color)

            // Quick temp buttons
            HStack(spacing: 8) {
                ForEach(quickTemps, id: \.self) { temp in
                    Button("\(temp)°") {
                        targetTemp = temp
                        onSet(temp)
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(targetTemp == temp ? color : Color(.systemGray5))
                    .foregroundColor(targetTemp == temp ? .white : .primary)
                    .cornerRadius(8)
                }
                Spacer()
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private var quickTemps: [Int] {
        if title == "Düse" {
            return [0, 190, 210, 230, 250]
        } else {
            return [0, 50, 60, 70, 80, 100]
        }
    }
}

struct SliderControlSection: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String
    let currentValue: Int
    let color: Color
    let onSet: (Int) -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(value)\(unit)")
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(color)
            }

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Int($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
            .tint(color)

            HStack {
                Text("\(range.lowerBound)\(unit)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Aktuell: \(currentValue)\(unit)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(range.upperBound)\(unit)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button("Anwenden") {
                onSet(value)
            }
            .buttonStyle(.borderedProminent)
            .tint(color)
            .frame(maxWidth: .infinity)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
}

struct FanSpeedView: View {
    let speed: Int

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Lüfter")
                    .font(.headline)
                Spacer()
                Text("\(speed)%")
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.medium)
            }

            HStack(spacing: 4) {
                ForEach(0..<10, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index < speed / 10 ? Color.blue : Color(.systemGray5))
                        .frame(height: 20)
                        .animation(.easeInOut(duration: 0.3), value: speed)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
}

#Preview("Controls") {
    ControlsView()
}