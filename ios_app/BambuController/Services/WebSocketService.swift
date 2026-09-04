//  WebSocketService.swift
//  BambuController
//
//  WebSocket client for real-time printer updates

import Foundation
import Combine

@MainActor
class WebSocketService: ObservableObject {
    static let shared = WebSocketService()

    @Published var isConnected = false
    @Published var lastError: String?

    private var webSocketTask: URLSessionWebSocketTask?
    private let session = URLSession.shared
    private var reconnectTimer: Timer?
    private let maxReconnectAttempts = 5
    private var reconnectAttempts = 0

    // Callbacks
    var onStatusUpdate: ((PrinterStatus) -> Void)?
    var onEvent: ((WSMessage) -> Void)?

    private init() {}

    func connect() {
        guard !isConnected else { return }
        guard let url = URL(string: AppSettings.shared.wsURL) else {
            lastError = "Ungültige WebSocket-URL"
            return
        }

        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        reconnectAttempts = 0

        receiveMessage()
    }

    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessage() // Continue listening

            case .failure(let error):
                Task { @MainActor in
                    self.handleDisconnect(error: error)
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseMessage(text)
            }
        @unknown default:
            break
        }
    }

    private func parseMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        do {
            let wsMessage = try JSONDecoder().decode(WSMessage.self, from: data)

            if wsMessage.type == "status", let wsData = wsMessage.data {
                let status = parsePrinterStatus(wsData)
                onStatusUpdate?(status)
            } else if wsMessage.type == "event" {
                onEvent?(wsMessage)
            }
        } catch {
            print("Failed to parse WS message: \(error)")
        }
    }

    private func parsePrinterStatus(_ data: WSData) -> PrinterStatus {
        let state = PrinterState(rawValue: data.state ?? "unknown") ?? .unknown

        let printJob = PrintJobInfo(
            name: data.printJob?.name ?? "",
            progress: data.printJob?.progress ?? 0,
            currentLayer: data.printJob?.currentLayer ?? 0,
            totalLayers: data.printJob?.totalLayers ?? 0,
            elapsedTime: data.printJob?.elapsedTime ?? 0,
            remainingTime: data.printJob?.remainingTime ?? 0,
            filamentType: data.printJob?.filamentType ?? "",
            filamentColor: data.printJob?.filamentColor ?? ""
        )

        return PrinterStatus(
            state: state,
            nozzleTemp: data.nozzleTemp ?? 0,
            nozzleTargetTemp: data.nozzleTargetTemp ?? 0,
            bedTemp: data.bedTemp ?? 0,
            bedTargetTemp: data.bedTargetTemp ?? 0,
            chamberTemp: data.chamberTemp ?? 0,
            printJob: printJob,
            wifiSignal: data.wifiSignal ?? 0,
            errorCode: data.errorCode ?? 0,
            fanSpeed: data.fanSpeed ?? 0,
            printSpeed: data.printSpeed ?? 100,
            flowRate: data.flowRate ?? 100
        )
    }

    private func handleDisconnect(error: Error) {
        isConnected = false
        lastError = error.localizedDescription

        // Auto-reconnect with exponential backoff
        if reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            let delay = min(pow(2.0, Double(reconnectAttempts)) * 1.0, 30.0)

            reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.connect()
                }
            }
        }
    }

    // Called when app becomes active
    func handleAppActive() {
        if !isConnected && AppSettings.shared.autoConnect {
            connect()
        }
    }

    // Called when app goes to background
    func handleAppBackground() {
        // Keep connection alive in background for a bit
    }
}