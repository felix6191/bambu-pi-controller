// DashboardView.swift - Main dashboard with printer status overview
import SwiftUI

struct DashboardView: View {
    @ObservedObject private var vm = PrinterViewModel.shared
    @StateObject private var ws = WebSocketService.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    PrinterStatusCard(status: vm.status, live: ws.isConnected)
                    if let s = vm.status { TemperatureCard(status: s) }
                    if let s = vm.status, s.state == .printing || s.state == .paused { PrintJobCard(status: s) }
                    QuickActionsCard()
                    Spacer(minLength: 100)
                }.padding()
            }
            .navigationTitle("Bambu A1")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { ConnectionIndicator(connected: ws.isConnected && vm.status != nil) } }
            .refreshable { await vm.loadStatus() }
            .alert("Fehler", isPresented: $vm.showError, presenting: vm.errorMessage) { _ in Button("OK", role: .cancel) {} } message: { Text($0) }
        }
    }
}

// MARK: - Subviews

private struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
            )
    }
}

struct PrinterStatusCard: View {
    let status: PrinterStatus?
    var live: Bool = false
    private var state: PrinterState { status?.state ?? .unknown }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Druckerstatus").font(.caption).foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        Image(systemName: state.systemImage).font(.title2).foregroundColor(state.color)
                        Text(state.displayName).font(.title2).fontWeight(.semibold)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if let s = status { WifiSignalView(signal: s.wifiSignal) }
                    LivePill(live: live)
                }
            }
            if let s = status, s.state == .printing || s.state == .paused {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("Fortschritt").font(.caption).foregroundColor(.secondary); Spacer(); Text("\(Int(s.progressClamped))%").font(.caption).fontWeight(.medium).monospacedDigit() }
                    ProgressView(value: s.progressClamped / 100)
                        .progressViewStyle(LinearProgressViewStyle(tint: .bambuBlue))
                        .scaleEffect(y: 2)
                        .animation(.easeInOut(duration: 0.4), value: s.printJob.progress)
                }
            } else if status == nil {
                Text("Noch keine Daten — Server in Einstellungen eintragen und „Verbindung testen“.")
                    .font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.modifier(Card())
    }
}

private extension PrinterStatus {
    var progressClamped: Double { Swift.min(Swift.max(0, printJob.progress), 100) }
}

struct LivePill: View {
    let live: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(live ? Color.green : Color.gray).frame(width: 7, height: 7)
            Text(live ? "LIVE" : "OFFLINE").font(.caption2).fontWeight(.bold)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background((live ? Color.green : Color.gray).opacity(0.15))
        .foregroundColor(live ? .green : .secondary)
        .clipShape(Capsule())
    }
}

struct WifiSignalView: View {
    let signal: Int
    var bars: Int { signal == 0 ? 0 : signal >= -50 ? 4 : signal >= -60 ? 3 : signal >= -70 ? 2 : signal >= -80 ? 1 : 0 }
    var body: some View {
        HStack(spacing: 2) { ForEach(0..<4, id: \.self) { i in RoundedRectangle(cornerRadius: 1).fill(i < bars ? Color.green : Color(.systemGray4)).frame(width: 3, height: CGFloat(4 + i * 3)) } }
    }
}

struct TemperatureCard: View {
    let status: PrinterStatus
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("Temperaturen").font(.headline); Spacer() }
            HStack(spacing: 20) {
                TempGauge(label: "Düse", current: status.nozzleTemp, target: status.nozzleTargetTemp, color: .orange)
                TempGauge(label: "Bett", current: status.bedTemp, target: status.bedTargetTemp, color: .red)
                TempGauge(label: "Kammer", current: status.chamberTemp, target: 0, color: .purple)
            }
        }.modifier(Card())
    }
}

struct TempGauge: View {
    let label: String; let current: Double; let target: Double; let color: Color
    private var fraction: Double { target > 0 ? Swift.min(Swift.max(0, current / target), 1) : 0 }
    var body: some View {
        VStack(spacing: 8) {
            Text(label).font(.caption).foregroundColor(.secondary)
            ZStack {
                Circle().stroke(Color(.systemGray5), lineWidth: 8).frame(width: 70, height: 70)
                Circle().trim(from: 0, to: fraction).stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round)).frame(width: 70, height: 70).rotationEffect(.degrees(-90)).animation(.easeInOut(duration: 0.5), value: current)
                VStack(spacing: 2) { Text("\(Int(current))°").font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit(); if target > 0 { Text("/ \(Int(target))°").font(.caption2).foregroundColor(.secondary).monospacedDigit() } }
            }
        }.frame(maxWidth: .infinity)
    }
}

struct PrintJobCard: View {
    let status: PrinterStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Aktueller Druck").font(.headline)
                Spacer()
                Text(status.state == .paused ? "PAUSIERT" : "DRUCKT").font(.caption).fontWeight(.bold).padding(.horizontal, 8).padding(.vertical, 4).background(status.state == .paused ? Color.orange : Color.blue).foregroundColor(.white).cornerRadius(8)
            }
            Text(status.printJob.name.isEmpty ? "Unbekannte Datei" : status.printJob.name).font(.title3).fontWeight(.medium).lineLimit(1)
            HStack(spacing: 24) {
                InfoItem(label: "Layer", value: "\(status.printJob.currentLayer) / \(status.printJob.totalLayers)")
                InfoItem(label: "Verstrichen", value: status.printJob.formattedElapsed)
                InfoItem(label: "Verbleibend", value: status.printJob.formattedRemaining)
            }
            if !status.printJob.filamentType.isEmpty {
                HStack { Image(systemName: "circle.fill").foregroundColor(filamentColor(status.printJob.filamentColor)); Text("\(status.printJob.filamentType) - \(status.printJob.filamentColor)").font(.caption).foregroundColor(.secondary) }
            }
        }.modifier(Card())
    }
    private func filamentColor(_ n: String) -> Color {
        let l = n.lowercased()
        if l.contains("black") { return .black }
        if l.contains("white") { return .gray }
        if l.contains("red") { return .red }
        if l.contains("blue") { return .blue }
        if l.contains("green") { return .green }
        if l.contains("yellow") { return .yellow }
        if l.contains("orange") { return .orange }
        if l.contains("purple") || l.contains("violet") { return .purple }
        return .gray
    }
}

struct InfoItem: View {
    let label: String; let value: String
    var body: some View {
        VStack(spacing: 2) { Text(value).font(.system(.body, design: .rounded)).fontWeight(.medium).monospacedDigit(); Text(label).font(.caption).foregroundColor(.secondary) }.frame(maxWidth: .infinity)
    }
}

struct QuickActionsCard: View {
    @ObservedObject private var vm = PrinterViewModel.shared
    @State private var showPrint = false
    @State private var confirmStop = false
    var body: some View {
        VStack(spacing: 12) {
            Text("Schnellzugriff").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                QuickActionButton(title: vm.status?.state == .printing ? "Pause" : "Drucken", icon: vm.status?.state == .printing ? "pause.fill" : "play.fill", color: vm.status?.state == .printing ? .orange : .green) {
                    if vm.status?.state == .printing { Task { await vm.pausePrint() } } else { showPrint = true }
                }
                if vm.status?.state == .paused {
                    QuickActionButton(title: "Fortsetzen", icon: "play.fill", color: .blue) { Task { await vm.resumePrint() } }
                }
                if vm.status?.state == .printing || vm.status?.state == .paused {
                    QuickActionButton(title: "Stopp", icon: "stop.fill", color: .red) { confirmStop = true }
                }
            }
        }.modifier(Card())
        .sheet(isPresented: $showPrint) { PrintStartSheet() }
        .alert("Druck wirklich stoppen?", isPresented: $confirmStop) {
            Button("Abbrechen", role: .cancel) {}
            Button("Stoppen", role: .destructive) { Task { await vm.stopPrint() } }
        }
    }
}

struct QuickActionButton: View {
    let title, icon: String; let color: Color; let action: () -> Void
    var body: some View {
        Button(action: action) { VStack(spacing: 8) { Image(systemName: icon).font(.title2); Text(title).font(.caption).fontWeight(.medium) }.frame(maxWidth: .infinity).padding(.vertical, 16).background(color.opacity(0.15)).foregroundColor(color).cornerRadius(12) }
    }
}

struct ConnectionIndicator: View {
    let connected: Bool
    var body: some View { HStack(spacing: 4) { Circle().fill(connected ? Color.green : Color.red).frame(width: 8, height: 8); Text(connected ? "Verbunden" : "Getrennt").font(.caption).foregroundColor(.secondary) } }
}

#Preview("Dashboard") { DashboardView().environmentObject(AppState.shared) }
