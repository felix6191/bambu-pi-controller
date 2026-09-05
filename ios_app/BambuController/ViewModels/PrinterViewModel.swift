// PrinterViewModel.swift - Main ViewModel for printer state and controls.
// In demo mode every command drives the local DemoService instead of the Pi.
import Foundation
import Combine
import SwiftUI

@MainActor
class PrinterViewModel: ObservableObject {
    static let shared = PrinterViewModel()

    @Published var status: PrinterStatus?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var capabilities: Capabilities?
    /// Live printer limits. Defaults to A1; refined from /capabilities when reachable.
    @Published var limits = PrinterLimits.bambuA1
    /// Command callback UI: which commands are in flight + last verified result
    @Published var pending: Set<String> = []
    @Published var feedback: CommandFeedback?

    var isDemo: Bool { AppSettings.shared.demoMode }

    private let api = APIService.shared
    private let ws = WebSocketService.shared
    private let demo = DemoService.shared

    private init() {
        ws.onStatusUpdate = { [weak self] s in self?.status = s }
        ws.onEvent = { [weak self] e in self?.handleEvent(e) }
        demo.onStatusUpdate = { [weak self] s in self?.status = s }
        if AppSettings.shared.demoMode {
            demo.start()
        } else if AppSettings.shared.autoConnect && !AppSettings.shared.serverURL.isEmpty {
            ws.connect()
        }
    }

    private func handleEvent(_ event: WSMessage) { print("Event: \(event.type)") }

    // MARK: - Connection / demo switching

    func enableDemo() {
        var s = AppSettings.shared; s.demoMode = true; s.commit()
        ws.disconnect()
        demo.start()
        Task { await loadStatus() }
    }

    func disableDemo() {
        var s = AppSettings.shared; s.demoMode = false; s.commit()
        demo.stop()
        status = nil
        if s.autoConnect && !s.serverURL.isEmpty { ws.connect() }
        Task { await loadStatus() }
    }

    func refreshCapabilities() async {
        guard !isDemo else { return }
        do {
            let caps = try await api.getCapabilities()
            capabilities = caps
            limits = PrinterLimits(maxNozzleTemp: caps.nozzleMaxTemp, maxBedTemp: caps.bedMaxTemp)
        } catch { /* keep A1 defaults */ }
    }

    // MARK: - Clamping helpers (prevent printer rejections before sending)

    func clampedNozzle(_ t: Int) -> Int { limits.clampNozzle(t) }
    func clampedBed(_ t: Int) -> Int { limits.clampBed(t) }
    func clampedSpeed(_ s: Int) -> Int { limits.clampSpeed(s) }
    func clampedFlow(_ f: Int) -> Int { limits.clampFlow(f) }

    func loadStatus() async {
        if isDemo { status = demo.status; return }
        isLoading = true; errorMessage = nil
        do {
            let s = try await api.getStatus()
            status = s
        }
        catch { errorMessage = error.localizedDescription; showError = true }
        isLoading = false
    }

    func startPrint(filename: String, bedTemp: Int = 0, nozzleTemp: Int = 0) async {
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorMessage = "Bitte einen Dateinamen eingeben"; showError = true; return }
        if isDemo { demo.startPrint(filename: name, bedTemp: clampedBed(bedTemp), nozzleTemp: clampedNozzle(nozzleTemp)); return }
        do { _ = try await api.startPrint(filename: name, bedTemp: clampedBed(bedTemp), nozzleTemp: clampedNozzle(nozzleTemp)) }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func pausePrint() async {
        if isDemo { demo.pause(); return }
        do { _ = try await api.pausePrint() }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func resumePrint() async {
        if isDemo { demo.resume(); return }
        do { _ = try await api.resumePrint() }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func stopPrint() async {
        if isDemo { demo.stopPrint(); return }
        do { _ = try await api.stopPrint() }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    // MARK: - Verified commands (callback: adopted by printer or not?)

    private func track(_ key: String, _ title: String, want: String, work: () async throws -> APIResponse) async -> Bool {
        pending.insert(key)
        defer { pending.remove(key) }
        do {
            let r = try await work()
            guard r.success else {
                publishFeedback(title: title, message: "Vom Drucker abgelehnt.", ok: false)
                return false
            }
            if r.isVerified {
                publishFeedback(title: title, message: "\(want) übernommen ✓", ok: true)
            } else {
                publishFeedback(title: title, message: "\(want) gesendet — Bestätigung steht noch aus, bitte gleich prüfen.", ok: false)
            }
            await loadStatusQuiet()
            return r.isVerified
        } catch {
            errorMessage = error.localizedDescription; showError = true
            return false
        }
    }

    private func publishFeedback(title: String, message: String, ok: Bool) {
        let fb = CommandFeedback(title: title, message: message, ok: ok)
        feedback = fb
        Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if feedback == fb { feedback = nil }
        }
    }

    private func loadStatusQuiet() async {
        if isDemo { status = demo.status; return }
        if let s = try? await api.getStatus() { status = s }
    }

    func setNozzleTemperature(_ temp: Int) async -> Bool {
        let want = clampedNozzle(temp)
        if isDemo { demo.setNozzle(want); publishFeedback(title: "Düse", message: "\(want)° übernommen ✓", ok: true); return true }
        return await track("nozzle", "Düse", want: "\(want)°") {
            try await api.setTemperature(nozzle: want, bed: nil)
        }
    }

    func setBedTemperature(_ temp: Int) async -> Bool {
        let want = clampedBed(temp)
        if isDemo { demo.setBed(want); publishFeedback(title: "Druckbett", message: "\(want)° übernommen ✓", ok: true); return true }
        return await track("bed", "Druckbett", want: "\(want)°") {
            try await api.setTemperature(nozzle: nil, bed: want)
        }
    }

    func setSpeedLevel(_ level: Int) async -> Bool {
        guard (1...4).contains(level) else { return false }
        let name = SpeedPreset.all.first(where: { $0.id == level })?.name ?? "\(level)"
        if isDemo { demo.setSpeedLevel(level); publishFeedback(title: "Geschwindigkeit", message: "\(name) übernommen ✓", ok: true); return true }
        return await track("speed", "Geschwindigkeit", want: name) {
            try await api.setSpeedLevel(level)
        }
    }

    func setPrintSpeed(_ speed: Int) async -> Bool {
        // Map percent onto the official preset ladder
        let lvl = speed <= 62 ? 1 : speed <= 112 ? 2 : speed <= 137 ? 3 : 4
        return await setSpeedLevel(lvl)
    }

    func setFlowRate(_ flow: Int) async -> Bool {
        let want = clampedFlow(flow)
        if isDemo { demo.setFlow(want); publishFeedback(title: "Flow", message: "\(want) % übernommen ✓", ok: true); return true }
        return await track("flow", "Flow", want: "\(want) %") {
            try await api.setFlow(want)
        }
    }

    func setLight(on: Bool) async -> Bool {
        if isDemo { demo.setLight(on: on); publishFeedback(title: "Bauraumlicht", message: on ? "Eingeschaltet ✓" : "Ausgeschaltet ✓", ok: true); return true }
        return await track("light", "Bauraumlicht", want: on ? "An" : "Aus") {
            try await api.setLight(on: on)
        }
    }

    func reconnect() {
        if isDemo { return }
        ws.disconnect(); ws.connect()
    }
}
