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

    func setNozzleTemperature(_ temp: Int) async {
        if isDemo { demo.setNozzle(clampedNozzle(temp)); return }
        do { _ = try await api.setTemperature(nozzle: clampedNozzle(temp), bed: nil) }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func setBedTemperature(_ temp: Int) async {
        if isDemo { demo.setBed(clampedBed(temp)); return }
        do { _ = try await api.setTemperature(nozzle: nil, bed: clampedBed(temp)) }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func setSpeedLevel(_ level: Int) async {
        guard (1...4).contains(level) else { return }
        if isDemo { demo.setSpeedLevel(level); return }
        do { _ = try await api.setSpeedLevel(level) }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func setPrintSpeed(_ speed: Int) async {
        // Map percent onto the official preset ladder
        let lvl = speed <= 62 ? 1 : speed <= 112 ? 2 : speed <= 137 ? 3 : 4
        await setSpeedLevel(lvl)
    }

    func setFlowRate(_ flow: Int) async {
        if isDemo { demo.setFlow(clampedFlow(flow)); return }
        do { _ = try await api.setFlow(clampedFlow(flow)) }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func setLight(on: Bool) async {
        if isDemo { demo.setLight(on: on); return }
        do { _ = try await api.setLight(on: on) }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func reconnect() {
        if isDemo { return }
        ws.disconnect(); ws.connect()
    }
}
