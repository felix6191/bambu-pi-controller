// DashboardView.swift - Home in premium companion-app style:
// header row, hero diagram, 2x2 stat cards with big metrics, job card, actions.
import SwiftUI

struct DashboardView: View {
    @ObservedObject private var vm = PrinterViewModel.shared
    @StateObject private var ws = WebSocketService.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let fb = vm.feedback { FeedbackBanner(feedback: fb) }
                    headerRow
                    PrinterDiagramView(status: vm.status).card()
                    TempChartCard(history: vm.tempHistory)
                    statGrid
                    if let s = vm.status, s.state == .printing || s.state == .paused {
                        PrintJobCard(status: s)
                    }
                    QuickActionsCard()
                    Spacer(minLength: 90)
                }.padding()
            }
            .navigationTitle("Bambu A1")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await vm.loadStatus() }
            .alert("Fehler", isPresented: $vm.showError, presenting: vm.errorMessage) { _ in Button("OK", role: .cancel) {} } message: { Text($0) }
        }
    }

    // MARK: - Header (avatar + name left, live + light right)

    private var headerRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(.secondarySystemGroupedBackground))
                    .frame(width: 52, height: 52)
                    .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
                Image(systemName: "printer.fill")
                    .font(.title2)
                    .foregroundColor(.primary)
                    .symbolEffect(.bounce, value: vm.status?.state)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bambu Lab A1")
                    .font(.title3).fontWeight(.bold)
                Text(vm.status?.state.displayName ?? "Verbinde …")
                    .font(.subheadline).foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    if vm.isDemo { Pill(text: "Demo", color: .purple) }
                    LivePill(live: vm.isDemo || (ws.isConnected && vm.status != nil))
                }
                if let s = vm.status {
                    WifiSignalView(signal: s.wifiSignal)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bambu Lab A1, \(vm.status?.state.displayName ?? "nicht verbunden")")
    }

    // MARK: - 2x2 stat grid

    private var statGrid: some View {
        let s = vm.status
        let progress = s.map { min(max($0.printJob.progress, 0), 100) } ?? 0
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Progress ring card
                VStack(alignment: .leading, spacing: 6) {
                    Text("Fortschritt").font(.caption).foregroundColor(.secondary)
                    HStack {
                        Spacer()
                        RingGauge(
                            fraction: progress / 100,
                            valueText: s == nil ? "–" : "\(Int(progress)) %",
                            caption: layerCaption
                        )
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                        .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 3)
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Fortschritt \(Int(progress)) Prozent, \(layerCaption)")

                StatCard(
                    icon: "thermometer.high",
                    caption: "Düse",
                    value: s.map { "\(Int($0.nozzleTemp))" } ?? "–",
                    unit: "°C",
                    footnote: s.map { "Ziel \($0.nozzleTargetTemp.Clean)° · \(heatState($0))" } ?? "Keine Daten",
                    tint: .orange
                )
            }
            HStack(spacing: 12) {
                StatCard(
                    icon: "square.stack.3d.up.fill",
                    caption: "Druckbett",
                    value: s.map { "\(Int($0.bedTemp))" } ?? "–",
                    unit: "°C",
                    footnote: s.map { "Ziel \($0.bedTargetTemp.Clean)° · \(heatState($0, bed: true))" } ?? "Keine Daten",
                    tint: .red
                )
                StatCard(
                    icon: "clock.fill",
                    caption: "Restzeit",
                    value: s.map { shortRemaining($0) } ?? "–",
                    unit: "",
                    footnote: s.map { "Läuft \($0.printJob.formattedElapsed)" } ?? "Kein Druck aktiv",
                    tint: .primary
                )
            }
        }
    }

    private var layerCaption: String {
        guard let s = vm.status, s.printJob.totalLayers > 0 else { return "Bereit" }
        return "Schicht \(s.printJob.currentLayer)/\(s.printJob.totalLayers)"
    }

    private func heatState(_ s: PrinterStatus, bed: Bool = false) -> String {
        let cur = bed ? s.bedTemp : s.nozzleTemp
        let tgt = bed ? s.bedTargetTemp : s.nozzleTargetTemp
        if tgt <= 0 { return "Aus" }
        if tgt - cur > 3 { return "Heizt" }
        if abs(tgt - cur) <= 3 { return "Bereit" }
        return "Kühlt ab"
    }

    private func shortRemaining(_ s: PrinterStatus) -> String {
        guard s.state == .printing || s.state == .paused else { return "–" }
        let m = s.printJob.remainingTime / 60, h = m / 60
        if h > 0 { return "\(h)h \(m % 60)m" }
        return "\(m)m"
    }
}

// MARK: - Subviews

private extension Double {
    /// "220" statt "220.0" für Temperatur-Labels
    var Clean: String {
        let i = Int(self)
        return self == Double(i) ? "\(i)" : String(format: "%.1f", self)
    }
}

struct WifiSignalView: View {
    let signal: Int
    var bars: Int { signal == 0 ? 0 : signal >= -50 ? 4 : signal >= -60 ? 3 : signal >= -70 ? 2 : signal >= -80 ? 1 : 0 }
    var body: some View {
        HStack(spacing: 2) { ForEach(0..<4, id: \.self) { i in RoundedRectangle(cornerRadius: 1).fill(i < bars ? Color.green : Color(.systemGray4)).frame(width: 3, height: CGFloat(4 + i * 3)) } }
            .accessibilityLabel(signal == 0 ? "WLAN unbekannt" : "WLAN-Signal \(signal) dBm")
    }
}

struct PrintJobCard: View {
    let status: PrinterStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Aktueller Druck").font(.headline)
                Spacer()
                Text(status.state == .paused ? "Pausiert" : "Druckt")
                    .font(.caption).fontWeight(.bold)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(status.state == .paused ? Color.orange : Color.blue)
                    .foregroundColor(.white).cornerRadius(8)
            }
            Text(status.printJob.name.isEmpty ? "Unbekannte Datei" : status.printJob.name)
                .font(.title3).fontWeight(.medium).lineLimit(1)
            HStack(spacing: 24) {
                InfoItem(label: "Verstrichen", value: status.printJob.formattedElapsed)
                InfoItem(label: "Verbleibend", value: status.printJob.formattedRemaining)
                InfoItem(label: "Lüfter", value: "\(status.fanSpeed) %")
            }
            if !status.printJob.filamentType.isEmpty {
                HStack { Image(systemName: "circle.fill").foregroundColor(filamentColor(status.printJob.filamentColor)); Text("\(status.printJob.filamentType) - \(status.printJob.filamentColor)").font(.caption).foregroundColor(.secondary) }
            }
        }.card()
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
                QuickActionButton(title: vm.status?.state == .printing ? "Pause" : "Drucken", icon: vm.status?.state == .printing ? "pause.fill" : "play.fill", color: vm.status?.state == .printing ? .orange : AppTheme.accent) {
                    if vm.status?.state == .printing { Task { await vm.pausePrint() } } else { showPrint = true }
                }
                if vm.status?.state == .paused {
                    QuickActionButton(title: "Fortsetzen", icon: "play.fill", color: .blue) { Task { await vm.resumePrint() } }
                }
                if vm.status?.state == .printing || vm.status?.state == .paused {
                    QuickActionButton(title: "Stopp", icon: "stop.fill", color: .red) { confirmStop = true }
                }
            }
        }.card()
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
            .accessibilityLabel(title)
    }
}

struct LivePill: View {
    let live: Bool
    var body: some View {
        HStack(spacing: 5) {
            if live {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                    .phaseAnimator([0.35, 1.0]) { dot, phase in dot.opacity(phase) }
                    animation: { _ in .easeInOut(duration: 1.1).repeatForever(autoreverses: true) }
            } else {
                Circle().fill(Color.gray).frame(width: 7, height: 7)
            }
            Text(live ? "Live" : "Offline").font(.caption2).fontWeight(.bold)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background((live ? Color.green : Color.gray).opacity(0.15))
        .foregroundColor(live ? .green : .secondary)
        .clipShape(Capsule())
    }
}

#Preview("Dashboard") { DashboardView().environmentObject(AppState.shared) }
