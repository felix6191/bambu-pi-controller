//  PrinterViewModel.swift
//  BambuController
//
//  Main ViewModel for printer state and controls

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

    private let apiService = APIService.shared
    private let wsService = WebSocketService.shared
    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupWebSocket()
    }

    private func setupWebSocket() {
        wsService.onStatusUpdate = { [weak self] status in
            Task { @MainActor in
                self?.status = status
            }
        }

        wsService.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleEvent(event)
            }
        }

        // Connect when settings are valid
        if AppSettings.shared.autoConnect && !AppSettings.shared.serverURL.isEmpty {
            wsService.connect()
        }
    }

    private func handleEvent(_ event: WSMessage) {
        // Handle specific events (print start, finish, error, etc.)
        print("Received event: \(event.type)")
    }

    // MARK: - Public Methods

    func loadStatus() async {
        isLoading = true
        errorMessage = nil

        do {
            let status = try await apiService.getStatus()
            self.status = status
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }

        isLoading = false
    }

    func startPrint(filename: String, bedTemp: Int = 0, nozzleTemp: Int = 0) async {
        do {
            _ = try await apiService.startPrint(filename: filename, bedTemp: bedTemp, nozzleTemp: nozzleTemp)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func pausePrint() async {
        do {
            _ = try await apiService.pausePrint()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func resumePrint() async {
        do {
            _ = try await apiService.resumePrint()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func stopPrint() async {
        do {
            _ = try await apiService.stopPrint()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func setNozzleTemperature(_ temp: Int) async {
        do {
            _ = try await apiService.setTemperature(nozzle: temp, bed: nil)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func setBedTemperature(_ temp: Int) async {
        do {
            _ = try await apiService.setTemperature(nozzle: nil, bed: temp)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func setPrintSpeed(_ speed: Int) async {
        do {
            _ = try await apiService.setSpeed(speed)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func setFlowRate(_ flow: Int) async {
        do {
            _ = try await apiService.setFlow(flow)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func reconnect() {
        wsService.connect()
    }
}