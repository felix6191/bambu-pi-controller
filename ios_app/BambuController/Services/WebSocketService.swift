// WebSocketService.swift - WebSocket client for real-time printer updates
import Foundation
import Combine

@MainActor
class WebSocketService: ObservableObject {
    static let shared = WebSocketService()

    @Published var isConnected = false
    @Published var lastError: String?

    private var task: URLSessionWebSocketTask?
    private let session = URLSession.shared
    private var reconnectTimer: Timer?
    private var pingTimer: Timer?
    private var attempts = 0
    private let maxAttempts = 5

    var onStatusUpdate: (@MainActor (PrinterStatus) -> Void)?
    var onEvent: (@MainActor (WSMessage) -> Void)?
    var onJob: (@MainActor (SliceJob) -> Void)?

    private init() {}

    func connect() {
        let ws = AppSettings.shared.wsURL
        guard !isConnected, !ws.isEmpty, let url = URL(string: ws), url.scheme == "ws" || url.scheme == "wss" else { return }
        disconnect(silent: true)
        task = session.webSocketTask(with: url)
        task?.resume()
        attempts = 0
        isConnected = true
        lastError = nil
        receive()
        startPing()
    }

    func disconnect(silent: Bool = false) {
        reconnectTimer?.invalidate(); reconnectTimer = nil
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        if !silent { isConnected = false }
        else { isConnected = false }
    }

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.task?.sendPing { [weak self] err in
                    if err != nil { Task { @MainActor in self?.handleDisconnect(err ?? URLError(.badServerResponse)) } }
                }
            }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            Task { @MainActor in
                switch result {
                case .success(let msg):
                    self.handle(msg)
                    self.receive()
                case .failure(let err):
                    self.handleDisconnect(err)
                }
            }
        }
    }

    private struct TypeOnly: Codable { let type: String }
    private struct JobEnvelope: Codable { let type: String; let data: SliceJob }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }
        guard let data = text.data(using: .utf8),
              let kind = try? JSONDecoder().decode(TypeOnly.self, from: data) else { return }

        if kind.type == "job" {
            if let env = try? JSONDecoder().decode(JobEnvelope.self, from: data) {
                onJob?(env.data)
            }
            return
        }
        guard let ws = try? JSONDecoder().decode(WSMessage.self, from: data) else { return }
        if ws.type == "status", let d = ws.data {
            onStatusUpdate?(parseStatus(d))
        } else if ws.type == "event" {
            onEvent?(ws)
        }
    }

    private func parseStatus(_ d: WSData) -> PrinterStatus { d.toStatus() }

    private func handleDisconnect(_ error: Error) {
        isConnected = false; lastError = error.localizedDescription
        guard attempts < maxAttempts else { return }
        attempts += 1
        let delay = min(pow(2.0, Double(attempts)), 30.0)
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.connect() }
        }
    }

    func handleAppActive() { if !isConnected && AppSettings.shared.autoConnect { connect() } }
    func handleAppBackground() {}
}