// APIService.swift - REST API client for Bambu Pi Controller
import Foundation
import Combine
import UIKit

@MainActor
class APIService: ObservableObject {
    static let shared = APIService()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    private init() {}

    private var baseURL: String { AppSettings.shared.baseURL }
    private var token: String { AppSettings.shared.apiToken }

    private func request<T: Decodable>(_ endpoint: String, method: String = "GET", body: Data? = nil, _ type: T.Type) async throws -> T {
        guard !baseURL.isEmpty, let url = URL(string: "\(baseURL)/api/v1\(endpoint)") else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch let e as URLError where e.code == .timedOut {
            throw APIError.timeout
        } catch {
            throw APIError.network(error)
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard 200...299 ~= http.statusCode else { throw APIError.httpError(http.statusCode, data) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
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
    func setSpeedLevel(_ level: Int) async throws -> APIResponse {
        struct L: Codable { let level: Int }
        return try await request("/printer/speed-level", method: "POST", body: try JSONEncoder().encode(L(level: level)), APIResponse.self)
    }
    func setLight(on: Bool) async throws -> APIResponse {
        struct L: Codable { let on: Bool }
        return try await request("/printer/light", method: "POST", body: try JSONEncoder().encode(L(on: on)), APIResponse.self)
    }
    func getCapabilities() async throws -> Capabilities {
        try await request("/printer/capabilities", Capabilities.self)
    }
    func setFlow(_ flow: Int) async throws -> APIResponse {
        try await request("/printer/flow", method: "POST", body: try JSONEncoder().encode(FlowRequest(flow: flow)), APIResponse.self)
    }

    // Phone-based printer setup: store credentials on the Pi + connect now
    func getPrinterConfig() async throws -> PrinterConfigStatus {
        try await request("/system/printer-config", PrinterConfigStatus.self)
    }
    func savePrinterConfig(host: String, serial: String, code: String) async throws -> PrinterConfigResult {
        struct Body: Codable {
            let printer_host: String
            let printer_serial: String
            let printer_access_code: String
        }
        return try await request("/system/printer-config", method: "POST",
            body: try JSONEncoder().encode(Body(printer_host: host, printer_serial: serial, printer_access_code: code)),
            PrinterConfigResult.self)
    }

    // Pairing ohne Tippen: Status/Claim gehen an eine BELIEBIGE Pi-URL (ohne Token)
    func pairingStatus(baseURL: String) async throws -> PairingStatus {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(base)/api/v1/pairing/status") else { throw APIError.invalidURL }
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(PairingStatus.self, from: data)
    }
    func claimPi(baseURL: String) async throws -> PairingClaim {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(base)/api/v1/pairing/claim") else { throw APIError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["device_name": UIDevice.current.name])
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 403 { throw APIError.httpError(403, data) }
        guard 200...299 ~= http.statusCode else { throw APIError.httpError(http.statusCode, data) }
        return try JSONDecoder().decode(PairingClaim.self, from: data)
    }

    // Pi sucht den Drucker im Heimnetz (nach Pairing, mit Token)
    func scanPrinters() async throws -> PrinterScanResult {
        try await request("/system/printer-scan", method: "POST", PrinterScanResult.self)
    }

    // Repair: Pi für ein neues Handy freigeben (Druckerconfig bleibt)
    func resetPairing() async throws -> APIResponse {
        try await request("/pairing/reset", method: "POST", APIResponse.self)
    }

    // Files: STL upload (multipart) + jobs
    func uploadFile(data: Data, filename: String) async throws -> SliceJob {
        guard !baseURL.isEmpty, let url = URL(string: "\(baseURL)/api/v1/files/upload") else { throw APIError.invalidURL }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url, timeoutInterval: 600)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let (respData, resp): (Data, URLResponse)
        do { (respData, resp) = try await session.upload(for: req, from: body) }
        catch let e as URLError where e.code == .timedOut { throw APIError.timeout }
        catch { throw APIError.network(error) }
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        if http.statusCode == 413 { throw APIError.httpError(413, respData) }
        guard 200...299 ~= http.statusCode else { throw APIError.httpError(http.statusCode, respData) }
        do { return try JSONDecoder().decode(SliceJob.self, from: respData) }
        catch { throw APIError.decodingError(error) }
    }

    func listJobs() async throws -> [SliceJob] {
        try await request("/files/jobs", JobList.self).jobs
    }

    func sliceJob(id: String, params: SliceParams) async throws -> SliceJob {
        try await request("/files/jobs/\(id)/slice", method: "POST", body: try JSONEncoder().encode(params), SliceJob.self)
    }

    func printJob(id: String) async throws -> SliceJob {
        try await request("/files/jobs/\(id)/print", method: "POST", SliceJob.self)
    }

    func deleteJob(id: String) async throws -> APIResponse {
        struct R: Codable { let success: Bool }
        let r: R = try await request("/files/jobs/\(id)", method: "DELETE", R.self)
        return APIResponse(success: r.success, verified: nil, via: nil)
    }

    // Original-Modell für die 3D-Vorschau (GET /files/uploads/{id})
    func downloadUpload(jobId: String) async throws -> Data {
        guard !baseURL.isEmpty, let url = URL(string: "\(baseURL)/api/v1/files/uploads/\(jobId)") else { throw APIError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch let e as URLError where e.code == .timedOut { throw APIError.timeout }
        catch { throw APIError.network(error) }
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        if http.statusCode == 404 { throw APIError.httpError(404, data) }
        guard 200...299 ~= http.statusCode else { throw APIError.httpError(http.statusCode, data) }
        return data
    }

    func getProfiles() async throws -> ProfilesResponse {
        try await request("/files/profiles", ProfilesResponse.self)
    }

    // Camera (backend accepts ?token= query since <img>/MJPEG can't set headers)
    func getCameraStreamURL() -> URL? {
        guard !baseURL.isEmpty else { return nil }
        return URL(string: "\(baseURL)/api/v1/camera/stream?token=\(token)")
    }
    func getCameraSnapshotURL() -> URL? {
        guard !baseURL.isEmpty else { return nil }
        return URL(string: "\(baseURL)/api/v1/camera/snapshot?token=\(token)")
    }
}

enum APIError: LocalizedError {
    case invalidURL, invalidResponse, httpError(Int, Data), decodingError(Error), notConnected, unauthorized, timeout, network(Error)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Keine Server-URL konfiguriert (Einstellungen)"
        case .invalidResponse: return "Ungültige Server-Antwort"
        case .httpError(let c, _): return "Server-Fehler: \(c)"
        case .decodingError(let e): return "Datenfehler: \(e.localizedDescription)"
        case .notConnected: return "Nicht mit Drucker verbunden"
        case .unauthorized: return "Falscher API-Token (Einstellungen prüfen)"
        case .timeout: return "Zeitüberschreitung — Pi erreichbar? (Tailscale an?)"
        case .network(let e): return "Netzwerkfehler: \(e.localizedDescription)"
        }
    }
}
