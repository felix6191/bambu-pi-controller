// SettingsView.swift - App settings, connection status, demo & onboarding
import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var showToken = false
    @State private var testResult: String?
    @State private var testing = false
    @State private var showOnboarding = false
    @State private var showResetConfirm = false
    @State private var showPiSearch = false
    @State private var repairResult: String?
    @State private var repairing = false
    @State private var remote: RemoteAccessStatus?
    @State private var remoteBusy = false
    @Environment(\.openURL) private var openURL
    @ObservedObject private var vm = PrinterViewModel.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        ConnectionDot(ok: connectionOK)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connectionTitle).font(.headline)
                            Text(connectionSubtitle).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if vm.isDemo { Pill(text: "DEMO", color: .purple) }
                    }
                } header: { Text("Status") }

                remoteAccessSection

                Section {
                    Button { showPiSearch = true } label: {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(AppTheme.accent)
                            Text("Pi automatisch suchen & verbinden")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(.secondary)
                        }
                    }
                    .sheet(isPresented: $showPiSearch) { PiSearchSheet() }
                    TextField("http://100.x.x.x:8000", text: $settings.serverURL)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .onChange(of: settings.serverURL) { _, _ in commit() }
                    HStack {
                        Text("API-Token")
                        Spacer()
                        Group {
                            if showToken { TextField("Token", text: $settings.apiToken) }
                            else { SecureField("Token", text: $settings.apiToken) }
                        }
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye") }
                            .touchTarget()
                            .accessibilityLabel(showToken ? "Token verbergen" : "Token anzeigen")
                    }
                    .onChange(of: settings.apiToken) { _, _ in commit() }
                    Toggle("Automatisch verbinden", isOn: $settings.autoConnect)
                        .onChange(of: settings.autoConnect) { _, _ in commit() }
                    if !settings.localServerURL.isEmpty || !settings.remoteServerURL.isEmpty {
                        HStack {
                            Text("Aktiv")
                            Spacer()
                            Text(settings.isUsingRemote ? "Remote (Tailscale)" : "Lokal (Heimnetz)")
                                .foregroundColor(.secondary)
                        }
                        .font(.footnote)
                    }
                } header: {
                    Text("Server (Raspberry Pi)")
                } footer: {
                    HintText(text: "Normalfall: oben auf „Pi automatisch suchen“ — nichts abtippen. Manuell nur für Profis (Heimnetz-IP zuhause, Tailscale-IP 100.x.x.x von unterwegs).")
                }

                Section {
                    Button { testConnection() } label: {
                        if testing { ProgressView().frame(maxWidth: .infinity) }
                        else { Text("Verbindung testen").frame(maxWidth: .infinity) }
                    }
                    .disabled(settings.serverURL.isEmpty || settings.apiToken.isEmpty || testing || vm.isDemo)
                    if let r = testResult {
                        Text(r).font(.footnote).foregroundColor(r.hasPrefix("✅") ? .green : .red)
                    }
                    Button {
                        Task { await repair() }
                    } label: {
                        if repairing { ProgressView().frame(maxWidth: .infinity) }
                        else { Text("Pi für neues Handy freigeben").frame(maxWidth: .infinity) }
                    }
                    .disabled(settings.serverURL.isEmpty || settings.apiToken.isEmpty || repairing || vm.isDemo)
                    if let r = repairResult {
                        Text(r).font(.footnote).foregroundColor(.secondary)
                    }
                }

                Section {
                    Toggle("Demo-Modus (simulierter Drucker)", isOn: Binding(
                        get: { settings.demoMode },
                        set: { v in settings.demoMode = v; commit(); v ? vm.enableDemo() : vm.disableDemo() }
                    ))
                    .tint(.purple)
                    Button("Einrichtung erneut durchlaufen") { showOnboarding = true }
                } header: {
                    Text("Modus")
                } footer: {
                    HintText(text: "Im Demo-Modus siehst du einen simulierten A1 — ideal zum Ausprobieren ohne Hardware.")
                }

                Section("Drucker (Bambu Lab A1, offiziell)") {
                    LabeledValue(label: "Düse max.", value: "\(vm.limits.maxNozzleTemp) °C")
                    LabeledValue(label: "Bett max.", value: "\(vm.limits.maxBedTemp) °C")
                    LabeledValue(label: "Bauraum", value: "256 × 256 × 256 mm")
                    LabeledValue(label: "Düse", value: "0,4 mm Edelstahl")
                    if let s = vm.status, !s.nozzleDiameter.isEmpty {
                        LabeledValue(label: "Gemeldet", value: "Ø \(s.nozzleDiameter) mm · SD: \(s.sdcard ? "ok" : "fehlt")")
                    }
                }

                Section("Info") {
                    LabeledValue(label: "Version", value: "1.0.0")
                    Link("Offizielle A1-Spezifikationen ↗", destination: URL(string: "https://bambulab.com/en/a1/tech-specs")!)
                    Button("Cache leeren", role: .destructive) {
                        URLCache.shared.removeAllCachedResponses()
                        testResult = "Cache geleert."
                    }
                    Button("Alle Einstellungen zurücksetzen", role: .destructive) { showResetConfirm = true }
                        .alert("Wirklich zurücksetzen?", isPresented: $showResetConfirm) {
                            Button("Abbrechen", role: .cancel) {}
                            Button("Zurücksetzen", role: .destructive) { resetAll() }
                        }
                }
            }
            .navigationTitle("Einstellungen")
            .fullScreenCover(isPresented: $showOnboarding) {
                ReOnboardingHost()
            }
            .onAppear {
                settings = AppSettings.shared
                Task { await loadRemote() }
            }
        }
    }

    // MARK: - Fernzugriff (Tailscale, explizites Opt-in)
    //
    // Nach dem lokalen Verbinden steht hier NUR „Heimnetz (lokal)".
    // Remote per Tailscale wird erst eingerichtet, wenn man es antippt:
    // Login-Link öffnen, Tailscale-App auch auf dem iPhone anmelden —
    // danach gibt es „Remote jetzt nutzen" / „Zurück zu lokal" als Fallback.

    @ViewBuilder
    private var remoteAccessSection: some View {
        Section {
            if !settings.remoteEnabled {
                // --- Noch nicht eingerichtet: lokal ist alles ---
                HStack {
                    Image(systemName: "house.fill").foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Heimnetz (lokal)").font(.subheadline).fontWeight(.medium)
                        Text("Für unterwegs noch nichts eingerichtet — alles läuft zuhause.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                if let r = remote, r.isRunning, let ip = r.tailscaleIp {
                    // Pi-Daemon ist (von früher) eingeloggt — NICHT als „Aktiv"
                    // verkaufen, sondern zur Übernahme anbieten.
                    Text("Der Pi ist bereits bei Tailscale angemeldet (\(ip)) — in der App aber noch nicht als Remote eingerichtet.")
                        .font(.caption).foregroundColor(.secondary)
                    Button("Remote-Adresse übernehmen (\(ip))") {
                        adoptRemote(ip: ip)
                    }
                    .disabled(vm.isDemo)
                } else if let link = remote?.authUrl, !link.isEmpty {
                    Text("Anmeldung angefangen, aber noch nicht abgeschlossen.")
                        .font(.caption).foregroundColor(.secondary)
                    Button {
                        if let url = URL(string: link) { openURL(url) }
                    } label: {
                        Text("Anmeldung fortsetzen")
                    }
                    Button("Status erneut prüfen") {
                        Task { await loadRemote() }
                    }
                    .disabled(remoteBusy)
                } else {
                    Button {
                        Task { await enableRemote() }
                    } label: {
                        if remoteBusy { ProgressView().frame(maxWidth: .infinity) }
                        else { Text("Remote-Fallback mit Tailscale einrichten").frame(maxWidth: .infinity) }
                    }
                    .disabled(remoteBusy || vm.isDemo)
                    if let m = remote?.message, !m.isEmpty {
                        Text(m).font(.caption).foregroundColor(.secondary)
                    }
                }
            } else {
                // --- Eingerichtet: Lokal bleibt Standard, Remote ist Fallback ---
                HStack {
                    Image(systemName: settings.isUsingRemote ? "globe" : "house.fill")
                        .foregroundColor(settings.isUsingRemote ? .blue : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.isUsingRemote ? "Remote aktiv" : "Lokal aktiv")
                            .font(.subheadline).fontWeight(.medium)
                        Text(remoteLine).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if remoteBusy { ProgressView() }
                }
                if !(remote?.isRunning ?? false) {
                    Text("Pi meldet Tailscale gerade nicht als verbunden — ggf. Anmeldung erneuern.")
                        .font(.caption).foregroundColor(.orange)
                    Button {
                        Task { await enableRemote() }
                    } label: {
                        Text("Erneut anmelden")
                    }
                    .disabled(remoteBusy || vm.isDemo)
                }
                if !settings.localServerURL.isEmpty && settings.serverURL != settings.localServerURL {
                    Button("Zurück zu lokal (\(settings.localServerURL))") {
                        useAddress(settings.localServerURL)
                    }
                }
                if !settings.remoteServerURL.isEmpty && settings.serverURL != settings.remoteServerURL {
                    Button("Remote jetzt nutzen (\(settings.remoteServerURL))") {
                        useAddress(settings.remoteServerURL)
                    }
                }
                if !settings.localServerURL.isEmpty && !settings.remoteServerURL.isEmpty {
                    Button("Automatisch wählen (erreichbare Adresse nehmen)") {
                        Task { await autoSelectAddress() }
                    }
                    .disabled(remoteBusy)
                }
                if remoteBusy { ProgressView().frame(maxWidth: .infinity) }
                Button("Remote wieder entfernen", role: .destructive) {
                    var s = AppSettings.shared
                    s.remoteEnabled = false
                    if s.isUsingRemote, !s.localServerURL.isEmpty {
                        s.serverURL = s.localServerURL
                    }
                    s.commit()
                    settings = AppSettings.shared
                    commit()
                }
            }
        } header: {
            Text("Verbindung: lokal & Remote")
        } footer: {
            HintText(text: "Zuhause immer lokal. Remote nur für unterwegs — braucht die Tailscale-App auf Pi UND iPhone (gleiches Konto).")
        }
    }

    private var remoteLine: String {
        var parts: [String] = []
        if !settings.localServerURL.isEmpty { parts.append("Lokal: \(settings.localServerURL)") }
        if !settings.remoteServerURL.isEmpty { parts.append("Remote: \(settings.remoteServerURL)") }
        if let m = remote?.message, !m.isEmpty, remote?.isRunning != true { parts.append(m) }
        return parts.joined(separator: " · ")
    }

    /// Aktive Adresse wechseln (lokal ↔ remote) + Verbindung neu aufbauen.
    private func useAddress(_ url: String) {
        var s = AppSettings.shared
        s.serverURL = url
        s.commit()
        settings = AppSettings.shared
        WebSocketService.shared.disconnect()
        if s.autoConnect && !s.demoMode { WebSocketService.shared.connect() }
        Task { await PrinterViewModel.shared.loadStatus() }
    }

    /// Pi-seitige Tailscale-Adresse in die App übernehmen (Opt-in),
    /// aktiv bleibt aber bewusst die lokale Adresse.
    private func adoptRemote(ip: String) {
        var s = AppSettings.shared
        s.remoteServerURL = "http://\(ip):8000"
        s.remoteEnabled = true
        s.useTailscale = true
        s.commit()
        settings = AppSettings.shared
    }

    /// Fallback: erreichbare Adresse nehmen — erst lokal, dann remote.
    private func autoSelectAddress() async {
        remoteBusy = true; defer { remoteBusy = false }
        let s = AppSettings.shared
        if !s.localServerURL.isEmpty, await healthOK(s.localServerURL) {
            useAddress(s.localServerURL)
            return
        }
        if !s.remoteServerURL.isEmpty, await healthOK(s.remoteServerURL) {
            useAddress(s.remoteServerURL)
            return
        }
        await loadRemote()
    }

    private func healthOK(_ base: String) async -> Bool {
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let endpoint = URL(string: b + "/health") else { return false }
        var req = URLRequest(url: endpoint, timeoutInterval: 4)
        req.setValue("Bearer \(AppSettings.shared.apiToken)", forHTTPHeaderField: "Authorization")
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    private func loadRemote() async {
        guard !vm.isDemo else { return }
        remote = try? await APIService.shared.remoteAccessStatus()
    }

    private func enableRemote() async {
        remoteBusy = true; defer { remoteBusy = false }
        do {
            let r = try await APIService.shared.enableRemoteAccess()
            remote = r
            if let link = r.authUrl, let url = URL(string: link) {
                openURL(url)   // Anmeldung im Browser; danach Status erneut prüfen
                Task {
                    for _ in 0..<6 {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        await loadRemote()
                        if remote?.isRunning == true { break }
                    }
                }
            } else if r.isRunning, let ip = r.tailscaleIp {
                // Login fertig: Adresse merken + Opt-in setzen — aktiv
                // bleibt bewusst die lokale Adresse (Remote ist Fallback).
                adoptRemote(ip: ip)
                await loadRemote()
            }
        } catch {
            remote = RemoteAccessStatus(installed: true, state: "error",
                                        authUrl: nil, tailscaleIp: nil,
                                        message: error.localizedDescription)
        }
    }

    // MARK: - Status

    private var connectionOK: Bool {
        if vm.isDemo { return true }
        return vm.status != nil
    }
    private var connectionTitle: String {
        if vm.isDemo { return "Demo-Drucker aktiv" }
        guard vm.status != nil else { return "Nicht verbunden" }
        return settings.isUsingRemote ? "Remote verbunden" : "Lokal verbunden"
    }
    private var connectionSubtitle: String {
        if vm.isDemo { return "Simulierter Bambu Lab A1" }
        if settings.serverURL.isEmpty { return "Keine Server-URL eingetragen" }
        if settings.remoteEnabled, !settings.isUsingRemote {
            return "\(settings.serverURL) · Remote bereit"
        }
        return settings.serverURL
    }

    // MARK: - Actions

    private func commit() {
        settings.commit()
        WebSocketService.shared.disconnect()
        if settings.autoConnect && !settings.demoMode { WebSocketService.shared.connect() }
    }

    private func testConnection() {
        testing = true; testResult = nil
        let url = settings.baseURL
        Task {
            do {
                guard let endpoint = URL(string: url + "/health") else { throw URLError(.badURL) }
                var req = URLRequest(url: endpoint, timeoutInterval: 12)
                req.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    testResult = "✅ Pi erreichbar."
                    await vm.refreshCapabilities()
                    await vm.loadStatus()
                } else { testResult = "❌ Server antwortet mit Fehler — Token prüfen." }
            } catch {
                testResult = "❌ Nicht erreichbar: \(error.localizedDescription)"
            }
            testing = false
        }
    }

    private func resetAll() {
        UserDefaults.standard.removeObject(forKey: "AppSettings")
        AppSettings.shared = AppSettings()
        settings = AppSettings.shared
        testResult = "Zurückgesetzt. Bitte Setup erneut durchlaufen."
    }

    private func repair() async {
        repairing = true; repairResult = nil
        defer { repairing = false }
        do {
            _ = try await APIService.shared.resetPairing()
            repairResult = "Pi freigegeben — neues Handy kann sich jetzt per Suche verbinden."
        } catch {
            repairResult = "Fehler: \(error.localizedDescription)"
        }
    }
}

private struct LabeledValue: View {
    let label, value: String
    var body: some View {
        HStack { Text(label); Spacer(); Text(value).foregroundColor(.secondary) }
    }
}

private struct ConnectionDot: View {
    let ok: Bool
    var body: some View {
        Circle().fill(ok ? Color.green : Color.red).frame(width: 12, height: 12)
    }
}

/// Re-runs onboarding from settings without touching the main gate
private struct ReOnboardingHost: View {
    @Environment(\.dismiss) var dismiss
    @State private var done = false
    var body: some View {
        SetupFlowView(finished: $done)
            .onChange(of: done) { _, v in if v { dismiss() } }
    }
}

/// Automatische Pi-Suche (Bonjour) + Verbinden per Tap — ohne Tippen.
private struct PiSearchSheet: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var discovery = PiDiscovery.shared
    @State private var pairing = false
    @State private var message: String?
    @State private var ok = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if discovery.pis.isEmpty {
                        HStack { Spacer()
                            VStack(spacing: 8) {
                                if discovery.searching { ProgressView("Suche läuft …") }
                                else { Text("Nichts gefunden.").foregroundColor(.secondary) }
                                Button("Erneut suchen") { discovery.start() }
                                    .buttonStyle(.bordered)
                                    .tint(AppTheme.accent)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 16)
                    } else {
                        ForEach(discovery.pis) { pi in
                            Button { Task { await pair(pi) } } label: {
                                HStack {
                                    Image(systemName: "server.rack").foregroundColor(AppTheme.accent)
                                    VStack(alignment: .leading) {
                                        Text(pi.name).foregroundColor(.primary)
                                        Text(pi.paired ? "Bereits vergeben" : "Bereit — antippen")
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if pairing { ProgressView() }
                                }
                            }
                            .disabled(pairing)
                        }
                    }
                } header: { Text("Gefundene Pis") }
                .headerProminence(.increased)
                if let m = message {
                    Section { Text(m).font(.footnote).foregroundColor(ok ? .green : .red) }
                }
                Section {
                    HintText(text: "Gleiches WLAN wie der Pi (kein Gast-WLAN). UnPaired-Pis lassen sich per Tap verbinden — Token kommt automatisch.")
                }
            }
            .navigationTitle("Pi suchen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Fertig") { dismiss() } }
            }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private func pair(_ pi: DiscoveredPi) async {
        pairing = true; message = nil; ok = false
        defer { pairing = false }
        for attempt in 1...3 {
            do {
                let claim = try await APIService.shared.claimPi(baseURL: pi.baseURL)
                var s = AppSettings.shared
                s.serverURL = pi.baseURL; s.localServerURL = pi.baseURL; s.apiToken = claim.apiToken
                s.demoWanted = false; s.commit()
                PrinterViewModel.shared.disableDemo()
                await PrinterViewModel.shared.loadStatus()
                message = "✅ Verbunden mit \(pi.name)."; ok = true
                return
            } catch {
                if let e = error as? APIError, case .httpError(403, _) = e {
                    message = "Dieser Pi gehört schon zu einem Handy — erst freigeben (unten in den Einstellungen oder „sudo bambu repair“)."
                    return
                }
                if attempt < 3 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
                else { message = "Klappt gerade nicht: \(error.localizedDescription)" }
            }
        }
    }
}

#Preview("Settings") { SettingsView() }
