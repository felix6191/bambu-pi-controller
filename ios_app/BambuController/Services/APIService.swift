//  APIService.swift
//  BambuController
//
//  REST API client for Bambu Pi Controller

import Foundation
import Combine

@MainActor
class APIService: ObservableObject {
    static let shared = APIService()

    private let session = URLSession.shared
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    private var baseURL: String {
        AppSettings.shared.baseURL
    }

    private var token: String {
        AppSettings.shared.apiToken
    }

    private func request<T: Decodable>(
        _ endpoint: String,
        method: String = "GET",
        body: Data? = nil,
        responseType: T.Type
    ) async throws -> T {
        guard let url = URL(string: "\(baseURL)/api/v1\(endpoint)") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard 200...299 ~= httpResponse.statusCode else {
            throw APIError.httpError(httpResponse.statusCode, data)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    // MARK: - Printer Endpoints

    func getStatus() async throws -> PrinterStatus {
        try await request("/printer/status", responseType: PrinterStatus.self)
    }

    func startPrint(filename: String, bedTemp: Int = 0, nozzleTemp: Int = 0) async throws -> APIResponse {
        let request = PrintStartRequest(filename: filename, bedTemp: bedTemp, nozzleTemp: nozzleTemp)
        let data = try JSONEncoder().encode(request)
        return try await request("/printer/print/start", method: "POST", body: data, responseType: APIResponse.self)
    }

    func pausePrint() async throws -> APIResponse {
        try await request("/printer/print/pause", method: "POST", responseType: APIResponse.self)
    }

    func resumePrint() async throws -> APIResponse {
        try await request("/printer/print/resume", method: "POST", responseType: APIResponse.self)
    }

    func stopPrint() async throws -> APIResponse {
        try await request("/printer/print/stop", method: "POST", responseType: APIResponse.self)
    }

    func setTemperature(nozzle: Int?, bed: Int?) async throws -> APIResponse {
        let request = TemperatureRequest(nozzle: nozzle, bed: bed)
        let data = try JSONEncoder().encode(request)
        return try await request("/printer/temperature", method: "POST", body: data, responseType: APIResponse.self)
    }

    func setSpeed(_ speed: Int) async throws -> APIResponse {
        let request = SpeedRequest(speed: speed)
        let data = try JSONEncoder().encode(request)
        return try await request("/printer/speed", method: "POST", body: data, responseType: APIResponse.self)
    }

    func setFlow(_ flow: Int) async throws -> APIResponse {
        let request = FlowRequest(flow: flow)
        let data = try JSONEncoder().encode(request)
        return try await request("/printer/flow", method: "POST", body: data, responseType: APIResponse.self)
    }

    // MARK: - Camera Endpoints

    func getCameraStreamURL() -> URL? {
        guard let url = URL(string: "\(baseURL)/api/v1/camera/stream?token=\(token)") else { return nil }
        return url
    }

    func getCameraSnapshotURL() -> URL? {
        guard let url = URL(string: "\(baseURL)/api/v1/camera/snapshot?token=\(token)") else { return nil }
        return url
    }
}

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, Data)
    case decodingError(Error)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Ungültige Server-URL"
        case .invalidResponse: return "Ungültige Server-Antwort"
        case .httpError(let code, _): return "Server-Fehler: \(code)"
        case .decodingError(let error): return "Datenfehler: \(error.localizedDescription)"
        case .notConnected: return "Nicht mit Drucker verbunden"
        }
    }
}