// APIService.swift - REST API client for Bambu Pi Controller
import Foundation
import Combine

@MainActor
class APIService: ObservableObject {
    static let shared = APIService()
    private let session = URLSession.shared

    private init() {}

    private var baseURL: String { AppSettings.shared.baseURL }
    private var token: String { AppSettings.shared.apiToken }

    private func request<T: Decodable>(_ endpoint: String, method: String = "GET", body: Data? = nil, _ type: T.Type) async throws -> T {
        guard let url = URL(string: "\(baseURL)/api/v1\(endpoint)") else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard 200...299 ~= http.statusCode else { throw APIError.httpError(http.statusCode, data) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // Printer
    func getStatus() async throws -> PrinterStatus { try await request("/printer/status", PrinterStatus.self) }
    func startPrint(filename: String, bedTemp: Int = 0, nozzleTemp: Int = 0) async throws -> APIResponse {
        try await request("/printer/print/start", method: "POST", body: try JSONEncoder().encode(PrintStartRequest(filename: filename, bedTemp: bedTemp, nozzleTemp: nozzleTemp)), APIResponse.self)
    }
    func pausePrint() async throws -> APIResponse { try await request("/printer/print/pause", method: "POST", APIResponse.self) }
    func resumePrint() async throws -> APIResponse { try await request("/printer/print/resume", method: "POST", APIResponse.self) }
    func stopPrint() async throws -> APIResponse { try await request("/printer/print/stop", method: "POST", APIResponse.self) }
    func setTemperature(nozzle: Int?, bed: Int?) async throws -> APIResponse {
        try await request("/printer/temperature", method: "POST", body: try JSONEncoder().encode(TemperatureRequest(nozzle: nozzle, bed: bed)), APIResponse.self)
    }
    func setSpeed(_ speed: Int) async throws -> APIResponse {
        try await request("/printer/speed", method: "POST", body: try JSONEncoder().encode(SpeedRequest(speed: speed)), APIResponse.self)
    }
    func setFlow(_ flow: Int) async throws -> APIResponse {
        try await request("/printer/flow", method: "POST", body: try JSONEncoder().encode(FlowRequest(flow: flow)), APIResponse.self)
    }

    // Camera
    func getCameraStreamURL() -> URL? { URL(string: "\(baseURL)/api/v1/camera/stream?token=\(token)") }
    func getCameraSnapshotURL() -> URL? { URL(string: "\(baseURL)/api/v1/camera/snapshot?token=\(token)") }
}

enum APIError: LocalizedError {
    case invalidURL, invalidResponse, httpError(Int, Data), decodingError(Error), notConnected
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Ungültige Server-URL"
        case .invalidResponse: return "Ungültige Server-Antwort"
        case .httpError(let c, _): return "Server-Fehler: \(c)"
        case .decodingError(let e): return "Datenfehler: \(e.localizedDescription)"
        case .notConnected: return "Nicht mit Drucker verbunden"
        }
    }
}