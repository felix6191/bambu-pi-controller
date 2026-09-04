//  DashboardView.swift
//  BambuController
//
//  Main dashboard with printer status overview

import SwiftUI

struct DashboardView: View {
    @StateObject private var printerVM = PrinterViewModel.shared
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Printer Status Card
                    PrinterStatusCard(status: printerVM.status)

                    // Temperature Card
                    if let status = printerVM.status {
                        TemperatureCard(status: status)
                    }

                    // Print Job Card
                    if let status = printerVM.status, status.state == .printing || status.state == .paused {
                        PrintJobCard(status: status)
                    }

                    // Quick Actions
                    QuickActionsCard()

                    Spacer(minLength: 100)
                }
                .padding()
            }
            .navigationTitle("Bambu A1")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ConnectionIndicator(isConnected: printerVM.status != nil)
                }
            }
            .refreshable {
                await printerVM.loadStatus()
            }
            .alert("Fehler", isPresented: $printerVM.showError, presenting: printerVM.errorMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error)
            }
        }
    }
}

// MARK: - Subviews

struct PrinterStatusCard: View {
    let status: PrinterStatus?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Druckerstatus")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        Image(systemName: currentState.systemImage)
                            .font(.title2)
                            .foregroundColor(Color(currentState.color))

                        Text(currentState.displayName)
                            .font(.title2)
                            .fontWeight(.semibold)
                    }
                }

                Spacer()

                // Wifi signal
                if let status = status {
                    WifiSignalView(signal: status.wifiSignal)
                }
            }

            // Progress bar for printing
            if let status = status, status.state == .printing || status.state == .paused {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Fortschritt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(status.printJob.progress))%")
                            .font(.caption)
                            .fontWeight(.medium)
                    }

                    ProgressView(value: status.printJob.progress / 100)
                        .progressViewStyle(LinearProgressViewStyle(tint: .bambuBlue))
                        .scaleEffect(y: 2)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private var currentState: PrinterState {
        status?.state ?? .unknown
    }
}

struct WifiSignalView: View {
    let signal: Int

    var signalStrength: Int {
        // RSSI to bars (-100 to -30)
        if signal >= -50 { return 4 }
        else if signal >= -60 { return 3 }
        else if signal >= -70 { return 2 }
        else if signal >= -80 { return 1 }
        else { return 0 }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < signalStrength ? Color.green : Color(.systemGray4))
                    .frame(width: 3, height: CGFloat(4 + index * 3))
            }
        }
    }
}

struct TemperatureCard: View {
    let status: PrinterStatus

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Temperaturen")
                    .font(.headline)
                Spacer()
            }

            HStack(spacing: 20) {
                TempGauge(
                    label: "Düse",
                    current: status.nozzleTemp,
                    target: status.nozzleTargetTemp,
                    color: .orange
                )

                TempGauge(
                    label: "Bett",
                    current: status.bedTemp,
                    target: status.bedTargetTemp,
                    color: .red
                )

                TempGauge(
                    label: "Kammer",
                    current: status.chamberTemp,
                    target: 0,
                    color: .purple
                )
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
}

struct TempGauge: View {
    let label: String
    let current: Double
    let target: Double
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            ZStack {
                Circle()
                    .stroke(Color(.systemGray5), lineWidth: 8)
                    .frame(width: 70, height: 70)

                Circle()
                    .trim(from: 0, to: min(current / max(target, 1), 1.0))
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 70, height: 70)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: current)

                VStack(spacing: 2) {
                    Text("\(Int(current))°")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    if target > 0 {
                        Text("/ \(Int(target))°")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct PrintJobCard: View {
    let status: PrinterStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Aktueller Druck")
                    .font(.headline)
                Spacer()
                Text(status.state == .paused ? "PAUSIERT" : "DRUCKT")
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(status.state == .paused ? Color.orange : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }

            Text(status.printJob.name)
                .font(.title3)
                .fontWeight(.medium)
                .lineLimit(1)

            HStack(spacing: 24) {
                InfoItem(label: "Layer", value: "\(status.printJob.currentLayer) / \(status.printJob.totalLayers)")
                InfoItem(label: "Verstrichen", value: status.printJob.formattedElapsed)
                InfoItem(label: "Verbleibend", value: status.printJob.formattedRemaining)
            }

            if !status.printJob.filamentType.isEmpty {
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundColor(filamentColor(status.printJob.filamentColor))
                    Text("\(status.printJob.filamentType) - \(status.printJob.filamentColor)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private func filamentColor(_ name: String) -> Color {
        let lower = name.lowercased()
        if lower.contains("black") { return .black }
        if lower.contains("white") { return .gray }
        if lower.contains("red") { return .red }
        if lower.contains("blue") { return .blue }
        if lower.contains("green") { return .green }
        if lower.contains("yellow") { return .yellow }
        if lower.contains("orange") { return .orange }
        if lower.contains("purple") || lower.contains("violet") { return .purple }
        return .gray
    }
}

struct InfoItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.body, design: .rounded))
                .fontWeight(.medium)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct QuickActionsCard: View {
    @StateObject private var printerVM = PrinterViewModel.shared
    @State private var showPrintSheet = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Schnellzugriff")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                QuickActionButton(
                    title: printerVM.status?.state == .printing ? "Pause" : "Drucken",
                    icon: printerVM.status?.state == .printing ? "pause.fill" : "play.fill",
                    color: printerVM.status?.state == .printing ? .orange : .green
                ) {
                    if printerVM.status?.state == .printing {
                        Task { await printerVM.pausePrint() }
                    } else {
                        showPrintSheet = true
                    }
                }

                if printerVM.status?.state == .paused {
                    QuickActionButton(
                        title: "Fortsetzen",
                        icon: "play.fill",
                        color: .blue
                    ) {
                        Task { await printerVM.resumePrint() }
                    }
                }

                if printerVM.status?.state == .printing || printerVM.status?.state == .paused {
                    QuickActionButton(
                        title: "Stopp",
                        icon: "stop.fill",
                        color: .red
                    ) {
                        Task { await printerVM.stopPrint() }
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .sheet(isPresented: $showPrintSheet) {
            PrintStartSheet()
        }
    }
}

struct QuickActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(12)
        }
    }
}

struct ConnectionIndicator: View {
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(isConnected ? "Verbunden" : "Getrennt")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

#Preview("Dashboard") {
    DashboardView()
        .environmentObject(AppState.shared)
}