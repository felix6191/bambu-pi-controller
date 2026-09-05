// PrinterViewModel.swift - Main ViewModel for printer state and controls
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
    /// Live printer limits. Defaults to A1; tightened from status when known.
    @Published var limits = PrinterLimits.bambuA1

    private let api = APIService.shared
    private let ws = WebSocketService.shared

    private init() {
        ws.onStatusUpdate = { [weak self] s in self?.status = s; self?.adaptLimits(from: s) }
        ws.onEvent = { [weak self] e in self?.handleEvent(e) }
        if AppSettings.shared.autoConnect && !AppSettings.shared.serverURL.isEmpty { ws.connect() }
    }

    private func handleEvent(_ event: WSMessage) { print("Event: \(event.type)") }

    /// Tighten limits from live data (never widen beyond physical A1 caps).
    private func adaptLimits(from s: PrinterStatus) {
        // If printer reports a lower target capability, respect it; never exceed hardware caps.
        // Currently the A1 caps are the source of truth; hook for future /capabilities endpoint.
        limits = PrinterLimits.bambuA1
    }

    // MARK: - Clamping helpers (prevent printer rejections before sending)

    func clampedNozzle(_ t: Int) -> Int { limits.clampNozzle(t) }
    func clampedBed(_ t: Int) -> Int { limits.clampBed(t) }
    func clampedSpeed(_ s: Int) -> Int { limits.clampSpeed(s) }
    func clampedFlow(_ f: Int) -> Int { limits.clampFlow(f) }

    func loadStatus() async {
        isLoading = true; errorMessage = nil
        do {
            let s = try await api.getStatus()
            status = s; adaptLimits(from: s)
        }
        catch { errorMessage = error.localizedDescription; showError = true }
        isLoading = false
    }

    func startPrint(filename: String, bedTemp: Int = 0, nozzleTemp: Int = 0) async {
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorMessage = "Dateiname fehlt"; showError = true; return }
        do { _ = try await api.startPrint(filename: name, bedTemp: clampedBed(bedTemp), nozzleTemp: clampedNozzle(nozzleTemp)) }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func pausePrint() async {
        do { _ = try await api.pausePrint() }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func resumePrint() async {
        do { _ = try await api.resumePrint() }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func stopPrint() async {
        do { _ = try await api.stopPrint() }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func setNozzleTemperature(_ temp: Int) async {
        do { _ = try await api.setTemperature(nozzle: clampedNozzle(temp), bed: nil) }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func setBedTemperature(_ temp: Int) async {
        do { _ = try await api.setTemperature(nozzle: nil, bed: clampedBed(temp)) }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func setPrintSpeed(_ speed: Int) async {
        do { _ = try await api.setSpeed(clampedSpeed(speed)) }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func setFlowRate(_ flow: Int) async {
        do { _ = try await api.setFlow(clampedFlow(flow)) }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func reconnect() { ws.disconnect(); ws.connect() }
}
