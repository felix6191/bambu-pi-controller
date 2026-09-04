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

    private let api = APIService.shared
    private let ws = WebSocketService.shared

    private init() {
        ws.onStatusUpdate = { [weak self] s in Task { @MainActor in self?.status = s } }
        ws.onEvent = { [weak self] e in Task { @MainActor in self?.handleEvent(e) } }
        if AppSettings.shared.autoConnect && !AppSettings.shared.serverURL.isEmpty { ws.connect() }
    }

    private func handleEvent(_ event: WSMessage) { print("Event: \(event.type)") }

    func loadStatus() async {
        isLoading = true; errorMessage = nil
        do { status = try await api.getStatus() }
        catch { errorMessage = error.localizedDescription; showError = true }
        isLoading = false
    }

    func startPrint(filename: String, bedTemp: Int = 0, nozzleTemp: Int = 0) async {
        do { _ = try await api.startPrint(filename: filename, bedTemp: bedTemp, nozzleTemp: nozzleTemp) }
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
        do { _ = try await api.setTemperature(nozzle: temp, bed: nil) }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func setBedTemperature(_ temp: Int) async {
        do { _ = try await api.setTemperature(nozzle: nil, bed: temp) }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func setPrintSpeed(_ speed: Int) async {
        do { _ = try await api.setSpeed(speed) }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func setFlowRate(_ flow: Int) async {
        do { _ = try await api.setFlow(flow) }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    func reconnect() { ws.connect() }
}