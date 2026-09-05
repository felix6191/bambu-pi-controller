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

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }
        guard let data = text.data(using: .utf8),
              let ws = try? JSONDecoder().decode(WSMessage.self, from: data) else { return }

        if ws.type == "status", let d = ws.data {
            let status = parseStatus(d)
            onStatusUpdate?(status)
        } else if ws.type == "event" {
            onEvent?(ws)
        }
    }

    private func parseStatus(_ d: WSData) -> PrinterStatus {
        let state = PrinterState(rawValue: d.state ?? "unknown") ?? .unknown
        let job = PrintJobInfo(
            name: d.printJob?.name ?? "", progress: d.printJob?.progress ?? 0,
            currentLayer: d.printJob?.currentLayer ?? 0, totalLayers: d.printJob?.totalLayers ?? 0,
            elapsedTime: d.printJob?.elapsedTime ?? 0, remainingTime: d.printJob?.remainingTime ?? 0,
            filamentType: d.printJob?.filamentType ?? "", filamentColor: d.printJob?.filamentColor ?? ""
        )
        return PrinterStatus(
            state: state, nozzleTemp: d.nozzleTemp ?? 0, nozzleTargetTemp: d.nozzleTargetTemp ?? 0,
            bedTemp: d.bedTemp ?? 0, bedTargetTemp: d.bedTargetTemp ?? 0, chamberTemp: d.chamberTemp ?? 0,
            printJob: job, wifiSignal: d.wifiSignal ?? 0, errorCode: d.errorCode ?? 0,
            fanSpeed: d.fanSpeed ?? 0, printSpeed: d.printSpeed ?? 100, flowRate: d.flowRate ?? 100
        )
    }

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