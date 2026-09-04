//  Models.swift
//  BambuController
//
//  Data models for Bambu Lab printer status and API responses

import Foundation

// MARK: - Printer Status

struct PrinterStatus: Codable {
    let state: PrinterState
    let nozzleTemp: Double
    let nozzleTargetTemp: Double
    let bedTemp: Double
    let bedTargetTemp: Double
    let chamberTemp: Double
    let printJob: PrintJobInfo
    let wifiSignal: Int
    let errorCode: Int
    let fanSpeed: Int
    let printSpeed: Int
    let flowRate: Int

    enum CodingKeys: String, CodingKey {
        case state
        case nozzleTemp = "nozzle_temp"
        case nozzleTargetTemp = "nozzle_target_temp"
        case bedTemp = "bed_temp"
        case bedTargetTemp = "bed_target_temp"
        case chamberTemp = "chamber_temp"
        case printJob = "print_job"
        case wifiSignal = "wifi_signal"
        case errorCode = "error_code"
        case fanSpeed = "fan_speed"
        case printSpeed = "print_speed"
        case flowRate = "flow_rate"
    }
}

enum PrinterState: String, Codable, CaseIterable {
    case idle = "idle"
    case printing = "printing"
    case paused = "paused"
    case busy = "busy"
    case error = "error"
    case unknown = "unknown"

    var displayName: String {
        switch self {
        case .idle: return "Bereit"
        case .printing: return "Druckt"
        case .paused: return "Pausiert"
        case .busy: return "Beschäftigt"
        case .error: return "Fehler"
        case .unknown: return "Unbekannt"
        }
    }

    var color: String {
        switch self {
        case .idle: return "green"
        case .printing: return "blue"
        case .paused: return "orange"
        case .busy: return "purple"
        case .error: return "red"
        case .unknown: return "gray"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: return "checkmark.circle.fill"
        case .printing: return "printer.filled.and.paper.fill"
        case .paused: return "pause.circle.fill"
        case .busy: return "gear.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

struct PrintJobInfo: Codable {
    let name: String
    let progress: Double
    let currentLayer: Int
    let totalLayers: Int
    let elapsedTime: Int
    let remainingTime: Int
    let filamentType: String
    let filamentColor: String

    enum CodingKeys: String, CodingKey {
        case name
        case progress
        case currentLayer = "current_layer"
        case totalLayers = "total_layers"
        case elapsedTime = "elapsed_time"
        case remainingTime = "remaining_time"
        case filamentType = "filament_type"
        case filamentColor = "filament_color"
    }

    var formattedElapsed: String {
        formatTime(elapsedTime)
    }

    var formattedRemaining: String {
        formatTime(remainingTime)
    }

    private func formatTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - API Request/Response Models

struct TemperatureRequest: Codable {
    let nozzle: Int?
    let bed: Int?
}

struct SpeedRequest: Codable {
    let speed: Int
}

struct FlowRequest: Codable {
    let flow: Int
}

struct PrintStartRequest: Codable {
    let filename: String
    let bedTemp: Int
    let nozzleTemp: Int

    enum CodingKeys: String, CodingKey {
        case filename
        case bedTemp = "bed_temp"
        case nozzleTemp = "nozzle_temp"
    }
}

struct APIResponse: Codable {
    let success: Bool
}

// MARK: - WebSocket Messages

struct WSMessage: Codable {
    let type: String
    let data: WSData?

    enum CodingKeys: String, CodingKey {
        case type
        case data
    }
}

struct WSData: Codable {
    let state: String?
    let nozzleTemp: Double?
    let nozzleTargetTemp: Double?
    let bedTemp: Double?
    let bedTargetTemp: Double?
    let chamberTemp: Double?
    let printJob: WSPrintJob?
    let wifiSignal: Int?
    let errorCode: Int?
    let fanSpeed: Int?
    let printSpeed: Int?
    let flowRate: Int?

    enum CodingKeys: String, CodingKey {
        case state
        case nozzleTemp = "nozzle_temp"
        case nozzleTargetTemp = "nozzle_target_temp"
        case bedTemp = "bed_temp"
        case bedTargetTemp = "bed_target_temp"
        case chamberTemp = "chamber_temp"
        case printJob = "print_job"
        case wifiSignal = "wifi_signal"
        case errorCode = "error_code"
        case fanSpeed = "fan_speed"
        case printSpeed = "print_speed"
        case flowRate = "flow_rate"
    }
}

struct WSPrintJob: Codable {
    let name: String?
    let progress: Double?
    let currentLayer: Int?
    let totalLayers: Int?
    let elapsedTime: Int?
    let remainingTime: Int?
    let filamentType: String?
    let filamentColor: String?

    enum CodingKeys: String, CodingKey {
        case name
        case progress
        case currentLayer = "current_layer"
        case totalLayers = "total_layers"
        case elapsedTime = "elapsed_time"
        case remainingTime = "remaining_time"
        case filamentType = "filament_type"
        case filamentColor = "filament_color"
    }
}

// MARK: - App Settings

struct AppSettings: Codable {
    var serverURL: String = ""
    var apiToken: String = ""
    var useTailscale: Bool = true
    var autoConnect: Bool = true

    static let shared = AppSettings.load()

    static func load() -> AppSettings {
        if let data = UserDefaults.standard.data(forKey: "AppSettings"),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return settings
        }
        return AppSettings()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "AppSettings")
        }
    }

    var baseURL: String {
        serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
    }

    var wsURL: String {
        let url = baseURL.replacingOccurrences(of: "http", with: "ws")
        return "\(url)/ws?token=\(apiToken)"
    }
}