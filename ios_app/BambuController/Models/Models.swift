// Models.swift - Data models for Bambu Lab printer status and API responses
import Foundation
import SwiftUI

// MARK: - Printer Status

struct PrinterStatus: Codable {
    var state: PrinterState
    var nozzleTemp: Double
    var nozzleTargetTemp: Double
    var bedTemp: Double
    var bedTargetTemp: Double
    var chamberTemp: Double
    var printJob: PrintJobInfo
    var wifiSignal: Int
    var errorCode: Int
    var fanSpeed: Int
    var auxFanSpeed: Int
    var chamberFanSpeed: Int
    var speedLevel: Int
    var printSpeed: Int
    var flowRate: Int
    var nozzleDiameter: String
    var sdcard: Bool
    var chamberLight: String

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
        case auxFanSpeed = "aux_fan_speed"
        case chamberFanSpeed = "chamber_fan_speed"
        case speedLevel = "speed_level"
        case printSpeed = "print_speed"
        case flowRate = "flow_rate"
        case nozzleDiameter = "nozzle_diameter"
        case sdcard
        case chamberLight = "chamber_light"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(PrinterState.self, forKey: .state) ?? .unknown
        nozzleTemp = try c.decodeIfPresent(Double.self, forKey: .nozzleTemp) ?? 0
        nozzleTargetTemp = try c.decodeIfPresent(Double.self, forKey: .nozzleTargetTemp) ?? 0
        bedTemp = try c.decodeIfPresent(Double.self, forKey: .bedTemp) ?? 0
        bedTargetTemp = try c.decodeIfPresent(Double.self, forKey: .bedTargetTemp) ?? 0
        chamberTemp = try c.decodeIfPresent(Double.self, forKey: .chamberTemp) ?? 0
        printJob = try c.decodeIfPresent(PrintJobInfo.self, forKey: .printJob) ?? PrintJobInfo(name: "", progress: 0, currentLayer: 0, totalLayers: 0, elapsedTime: 0, remainingTime: 0, filamentType: "", filamentColor: "")
        wifiSignal = try c.decodeIfPresent(Int.self, forKey: .wifiSignal) ?? 0
        errorCode = try c.decodeIfPresent(Int.self, forKey: .errorCode) ?? 0
        fanSpeed = try c.decodeIfPresent(Int.self, forKey: .fanSpeed) ?? 0
        auxFanSpeed = try c.decodeIfPresent(Int.self, forKey: .auxFanSpeed) ?? 0
        chamberFanSpeed = try c.decodeIfPresent(Int.self, forKey: .chamberFanSpeed) ?? 0
        speedLevel = try c.decodeIfPresent(Int.self, forKey: .speedLevel) ?? 2
        printSpeed = try c.decodeIfPresent(Int.self, forKey: .printSpeed) ?? 100
        flowRate = try c.decodeIfPresent(Int.self, forKey: .flowRate) ?? 100
        nozzleDiameter = try c.decodeIfPresent(String.self, forKey: .nozzleDiameter) ?? "0.4"
        sdcard = try c.decodeIfPresent(Bool.self, forKey: .sdcard) ?? true
        chamberLight = try c.decodeIfPresent(String.self, forKey: .chamberLight) ?? "unknown"
    }

    init(state: PrinterState = .unknown,
         nozzleTemp: Double = 0, nozzleTargetTemp: Double = 0,
         bedTemp: Double = 0, bedTargetTemp: Double = 0, chamberTemp: Double = 0,
         printJob: PrintJobInfo = PrintJobInfo(name: "", progress: 0, currentLayer: 0, totalLayers: 0, elapsedTime: 0, remainingTime: 0, filamentType: "", filamentColor: ""),
         wifiSignal: Int = 0, errorCode: Int = 0,
         fanSpeed: Int = 0, printSpeed: Int = 100, flowRate: Int = 100) {
        self.state = state
        self.nozzleTemp = nozzleTemp; self.nozzleTargetTemp = nozzleTargetTemp
        self.bedTemp = bedTemp; self.bedTargetTemp = bedTargetTemp
        self.chamberTemp = chamberTemp
        self.printJob = printJob
        self.wifiSignal = wifiSignal; self.errorCode = errorCode
        self.fanSpeed = fanSpeed; self.auxFanSpeed = 0; self.chamberFanSpeed = 0
        self.speedLevel = 2; self.printSpeed = printSpeed; self.flowRate = flowRate
        self.nozzleDiameter = "0.4"; self.sdcard = true; self.chamberLight = "unknown"
    }
}

/// Official Bambu speed presets (mirrors backend capabilities)
struct SpeedPreset: Identifiable {
    let id: Int
    let name: String
    let percent: Int
    let blurb: String
    static let all: [SpeedPreset] = [
        SpeedPreset(id: 1, name: "Silent", percent: 50, blurb: "Leise, z. B. nachts"),
        SpeedPreset(id: 2, name: "Standard", percent: 100, blurb: "Ausgewogen für den Alltag"),
        SpeedPreset(id: 3, name: "Sport", percent: 124, blurb: "Schneller bei guter Qualität"),
        SpeedPreset(id: 4, name: "Ludicrous", percent: 166, blurb: "Maximum — nur für robuste Teile"),
    ]
}

struct Capabilities: Codable {
    let model: String
    let nozzleMaxTemp: Int
    let bedMaxTemp: Int
    let speedLevels: [SpeedLevelInfo]

    enum CodingKeys: String, CodingKey {
        case model
        case nozzleMaxTemp = "nozzle_max_temp"
        case bedMaxTemp = "bed_max_temp"
        case speedLevels = "speed_levels"
    }
}

struct SpeedLevelInfo: Codable, Identifiable {
    var id: Int { level }
    let level: Int
    let name: String
    let percent: Int
}

// MARK: - File pipeline (STL → G-code → print)

enum JobStage: String, Codable {
    case uploaded, queued, slicing, sliced, uploading, starting, printing, done, failed

    var displayName: String {
        switch self {
        case .uploaded: return "Hochgeladen"
        case .queued: return "In Warteschlange"
        case .slicing: return "Wird gesliced"
        case .sliced: return "Bereit"
        case .uploading: return "Wird übertragen"
        case .starting: return "Startet"
        case .printing: return "Druckt"
        case .done: return "Fertig"
        case .failed: return "Fehlgeschlagen"
        }
    }

    var systemImage: String {
        switch self {
        case .uploaded: return "tray.and.arrow.down.fill"
        case .queued: return "clock.fill"
        case .slicing: return "cpu.fill"
        case .sliced: return "checkmark.seal.fill"
        case .uploading: return "arrow.up.circle.fill"
        case .starting: return "play.circle.fill"
        case .printing: return "printer.filled.and.paper"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var isBusy: Bool { [.queued, .slicing, .uploading, .starting, .printing].contains(self) }
}

struct SliceJob: Codable, Identifiable {
    let id: String
    let filename: String
    let sizeBytes: Int
    let stage: JobStage
    let progress: Double
    let filament: String
    let quality: String
    let supports: Bool
    let infill: Int
    let gcodeName: String
    let error: String

    enum CodingKeys: String, CodingKey {
        case id, filename, stage, progress, filament, quality, supports, infill, error
        case sizeBytes = "size_bytes"
        case gcodeName = "gcode_name"
    }

    var sizeText: String {
        let mb = Double(sizeBytes) / 1_048_576
        return mb >= 1 ? String(format: "%.1f MB", mb) : "\(max(1, sizeBytes / 1024)) KB"
    }
}

struct JobList: Codable { let jobs: [SliceJob] }

struct SliceParams: Codable {
    var filament: String = "pla"
    var quality: String = "standard"
    var supports: Bool = false
    var infill: Int = 15
    // Erweitert (nil = Profilwert, Desktop-Niveau)
    var layerHeight: Double?
    var walls: Int?
    var brim: Bool?
    var nozzleTemp: Int?
    var bedTemp: Int?

    enum CodingKeys: String, CodingKey {
        case filament, quality, supports, infill
        case layerHeight = "layer_height"
        case walls
        case brim
        case nozzleTemp = "nozzle_temp"
        case bedTemp = "bed_temp"
    }
}

struct FilamentInfo: Codable {
    let name: String
    let nozzle: Int
    let bed: Int
    let note: String?
}

struct QualityInfo: Codable {
    let name: String
    let layerMm: Double
    let note: String

    enum CodingKeys: String, CodingKey {
        case name, note
        case layerMm = "layer_mm"
    }
}

struct ProfilesResponse: Codable {
    let filaments: [String: FilamentInfo]
    let qualities: [String: QualityInfo]
    let slicer: String
}

enum PrinterState: String, Codable, CaseIterable {
    case idle = "idle", printing = "printing", paused = "paused", busy = "busy", error = "error", unknown = "unknown"

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

    var color: Color {
        switch self {
        case .idle: return .green
        case .printing: return .blue
        case .paused: return .orange
        case .busy: return .purple
        case .error: return .red
        case .unknown: return .gray
        }
    }

    var systemImage: String {
        switch self {
        case .idle: return "checkmark.circle.fill"
        case .printing: return "printer.filled.and.paper"
        case .paused: return "pause.circle.fill"
        case .busy: return "gear.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

/// Physical printer limits (Bambu Lab A1 defaults).
/// All setters clamp to these *before* sending, so the printer never
/// rejects a command and the user never sees a preventable error.
struct PrinterLimits: Codable, Equatable {
    var maxNozzleTemp: Int = 300
    var maxBedTemp: Int = 100
    var minSpeed: Int = 50
    var maxSpeed: Int = 200
    var minFlow: Int = 50
    var maxFlow: Int = 150

    static let bambuA1 = PrinterLimits()

    func clampNozzle(_ t: Int) -> Int { Swift.min(Swift.max(0, t), maxNozzleTemp) }
    func clampBed(_ t: Int) -> Int { Swift.min(Swift.max(0, t), maxBedTemp) }
    func clampSpeed(_ s: Int) -> Int { Swift.min(Swift.max(minSpeed, s), maxSpeed) }
    func clampFlow(_ f: Int) -> Int { Swift.min(Swift.max(minFlow, f), maxFlow) }
}

struct PrintJobInfo: Codable {
    var name: String
    var progress: Double
    var currentLayer: Int
    var totalLayers: Int
    var elapsedTime: Int
    var remainingTime: Int
    var filamentType: String
    var filamentColor: String

    enum CodingKeys: String, CodingKey {
        case name, progress
        case currentLayer = "current_layer"
        case totalLayers = "total_layers"
        case elapsedTime = "elapsed_time"
        case remainingTime = "remaining_time"
        case filamentType = "filament_type"
        case filamentColor = "filament_color"
    }

    var formattedElapsed: String { formatTime(elapsedTime) }
    var formattedRemaining: String { formatTime(remainingTime) }

    private func formatTime(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - API Request/Response Models

struct TemperatureRequest: Codable { let nozzle: Int?; let bed: Int? }
struct SpeedRequest: Codable { let speed: Int }
struct FlowRequest: Codable { let flow: Int }
struct PrintStartRequest: Codable {
    let filename: String
    var bedTemp: Int
    var nozzleTemp: Int
    enum CodingKeys: String, CodingKey { case filename; case bedTemp = "bed_temp"; case nozzleTemp = "nozzle_temp" }
}
struct APIResponse: Codable {
    let success: Bool
    let verified: Bool?
    let via: String?
    var isVerified: Bool { success && (verified ?? true) }
    var needsAttention: Bool { success && !(verified ?? true) }
}

struct PrinterConfigStatus: Codable {
    let configured: Bool
    let printerHost: String?
    let printerSerial: String?
    let printerConnected: Bool

    enum CodingKeys: String, CodingKey {
        case configured
        case printerHost = "printer_host"
        case printerSerial = "printer_serial"
        case printerConnected = "printer_connected"
    }
}

struct PrinterConfigResult: Codable {
    let success: Bool
    let printerConnected: Bool
    let message: String

    enum CodingKeys: String, CodingKey {
        case success
        case printerConnected = "printer_connected"
        case message
    }
}

// MARK: - Pairing (kein Tippen) + Drucker-Suche

struct PairingStatus: Codable {
    let paired: Bool
    let piId: String
    let version: Int

    enum CodingKeys: String, CodingKey {
        case paired
        case piId = "pi_id"
        case version
    }
}

struct PairingClaim: Codable {
    let apiToken: String
    let piId: String

    enum CodingKeys: String, CodingKey {
        case apiToken = "api_token"
        case piId = "pi_id"
    }
}

struct PrinterCandidate: Codable, Identifiable {
    var id: String { ip }
    let ip: String
    let ms: Int
}

struct PrinterScanResult: Codable {
    let prefix: String
    let candidates: [PrinterCandidate]
}

// MARK: - Fernzugriff (Tailscale), aus der App gestartet

struct RemoteAccessStatus: Codable {
    let installed: Bool
    let state: String
    let authUrl: String?
    let tailscaleIp: String?
    let message: String

    enum CodingKeys: String, CodingKey {
        case installed, state, message
        case authUrl = "auth_url"
        case tailscaleIp = "tailscale_ip"
    }

    var isRunning: Bool { state == "Running" && !(tailscaleIp ?? "").isEmpty }
}

// MARK: - WebSocket Messages

struct WSMessage: Codable { let type: String; let data: WSData? }
struct WSData: Codable {
    let state: String?
    var nozzleTemp: Double?; let nozzleTargetTemp: Double?
    var bedTemp: Double?; let bedTargetTemp: Double?
    var chamberTemp: Double?
    var printJob: WSPrintJob?
    var wifiSignal: Int?; let errorCode: Int?
    var fanSpeed: Int?; let auxFanSpeed: Int?; let chamberFanSpeed: Int?
    var speedLevel: Int?; let printSpeed: Int?; let flowRate: Int?
    var nozzleDiameter: String?; let sdcard: Bool?; let chamberLight: String?

    enum CodingKeys: String, CodingKey {
        case state
        case nozzleTemp = "nozzle_temp"; case nozzleTargetTemp = "nozzle_target_temp"
        case bedTemp = "bed_temp"; case bedTargetTemp = "bed_target_temp"
        case chamberTemp = "chamber_temp"
        case printJob = "print_job"
        case wifiSignal = "wifi_signal"; case errorCode = "error_code"
        case fanSpeed = "fan_speed"; case auxFanSpeed = "aux_fan_speed"; case chamberFanSpeed = "chamber_fan_speed"
        case speedLevel = "speed_level"; case printSpeed = "print_speed"; case flowRate = "flow_rate"
        case nozzleDiameter = "nozzle_diameter"; case sdcard; case chamberLight = "chamber_light"
    }

    /// Re-encode as backend JSON so the tolerant PrinterStatus decoder handles it.
    func toStatus() -> PrinterStatus {
        let enc = JSONEncoder()
        guard let data = try? enc.encode(self),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = try? JSONSerialization.data(withJSONObject: obj),
              let status = try? JSONDecoder().decode(PrinterStatus.self, from: body) else {
            return PrinterStatus()
        }
        return status
    }
}
struct WSPrintJob: Codable {
    let name: String?; let progress: Double?
    var currentLayer: Int?; let totalLayers: Int?
    var elapsedTime: Int?; let remainingTime: Int?
    var filamentType: String?; let filamentColor: String?
    enum CodingKeys: String, CodingKey {
        case name, progress
        case currentLayer = "current_layer"; case totalLayers = "total_layers"
        case elapsedTime = "elapsed_time"; case remainingTime = "remaining_time"
        case filamentType = "filament_type"; case filamentColor = "filament_color"
    }
}

// MARK: - App Settings

struct AppSettings: Codable {
    var serverURL: String = ""
    var apiToken: String = ""
    var useTailscale: Bool = true
    var autoConnect: Bool = true
    var onboarded: Bool = false
    var demoMode: Bool = false
    // Transient onboarding choice (demo vs. real), persisted harmlessly
    var demoWanted: Bool = true
    // Favorite defaults from the playful onboarding sliders (prefill for new prints)
    var defaultNozzleTemp: Int = 210
    var defaultBedTemp: Int = 60

    static var shared = AppSettings.load()

    static func load() -> AppSettings {
        if let data = UserDefaults.standard.data(forKey: "AppSettings"),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) { return s }
        return AppSettings()
    }

    /// Beim frischen App-Start aufrufen, solange das Tutorial NICHT komplett
    /// absolviert wurde: alle Einstellungen verwerfen, damit Pi und Drucker
    /// jedes Mal neu gesucht, zugeteilt und eingerichtet werden. Der Pi wird
    /// (mit dem alten Token) freigegeben, damit das Pairing erneut klappt.
    static func resetForFreshOnboarding() {
        let old = load()
        UserDefaults.standard.removeObject(forKey: "AppSettings")
        UserDefaults.standard.removeObject(forKey: "share.serverURL")
        UserDefaults.standard.removeObject(forKey: "share.apiToken")
        shared = AppSettings()
        if !old.serverURL.isEmpty && !old.apiToken.isEmpty {
            let base = old.baseURL
            let token = old.apiToken
            Task { @MainActor in await APIService.shared.resetPairing(baseURL: base, token: token) }
        }
    }

    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "AppSettings") } }

    /// Persist AND publish to the live singleton so API/WS pick up changes immediately.
    func commit() {
        save()
        Self.shared = self
    }

    var baseURL: String { serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL }
    var wsURL: String {
        guard !baseURL.isEmpty else { return "" }
        var url = baseURL
        if url.hasPrefix("https://") { url = url.replacingOccurrences(of: "https://", with: "wss://") }
        else if url.hasPrefix("http://") { url = url.replacingOccurrences(of: "http://", with: "ws://") }
        else { url = "ws://" + url }
        return url + "/ws?token=\(apiToken)"
    }
}