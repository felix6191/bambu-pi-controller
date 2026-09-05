// DemoService.swift - Simulated printer for onboarding demo & offline testing.
// Drives the exact same PrinterStatus model as the real backend, so every
// screen behaves identically in demo mode.
import Foundation
import Combine

@MainActor
class DemoService: ObservableObject {
    static let shared = DemoService()

    @Published private(set) var status = DemoService.initialStatus
    var onStatusUpdate: ((PrinterStatus) -> Void)?

    private var timer: Timer?
    private var tick = 0

    private init() {}

    static var initialStatus: PrinterStatus {
        PrinterStatus(
            state: .printing,
            nozzleTemp: 215.0, nozzleTargetTemp: 220.0,
            bedTemp: 64.0, bedTargetTemp: 65.0,
            chamberTemp: 31.0,
            printJob: PrintJobInfo(
                name: "Benchy.3mf", progress: 23.0,
                currentLayer: 46, totalLayers: 200,
                elapsedTime: 1860, remainingTime: 6240,
                filamentType: "PLA Basic", filamentColor: "Jade White"
            ),
            wifiSignal: -45, errorCode: 0,
            fanSpeed: 80, printSpeed: 100, flowRate: 100
        )
    }

    var running: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        push()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    private func push() { onStatusUpdate?(status) }

    private func advance() {
        tick += 1
        var s = status
        // Gentle temperature oscillation around targets
        let wobble = sin(Double(tick) * 0.6)
        if s.state == .printing {
            var job = s.printJob
            job.progress = min(100, job.progress + 0.4)
            job.currentLayer = min(job.totalLayers, Int(job.progress / 100 * Double(job.totalLayers)))
            job.elapsedTime += 2
            job.remainingTime = max(0, job.remainingTime - 2)
            s.printJob = job
            if job.progress >= 100 { s.state = .idle }
        }
        s.nozzleTemp = s.nozzleTargetTemp + wobble * 1.2
        s.bedTemp = s.bedTargetTemp + wobble * 0.6
        s.chamberTemp = 30.5 + wobble * 0.4
        status = s
        push()
    }

    // MARK: - Demo commands (mirror the real API)

    func pause() { if status.state == .printing { status.state = .paused; push() } }
    func resume() { if status.state == .paused { status.state = .printing; push() } }
    func stopPrint() {
        status.state = .idle
        status.printJob = PrintJobInfo(name: "", progress: 0, currentLayer: 0, totalLayers: 0, elapsedTime: 0, remainingTime: 0, filamentType: "", filamentColor: "")
        status.nozzleTargetTemp = 0; status.bedTargetTemp = 0
        push()
    }
    func startPrint(filename: String, bedTemp: Int, nozzleTemp: Int) {
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        status.state = .printing
        status.nozzleTargetTemp = Double(nozzleTemp); status.bedTargetTemp = Double(bedTemp)
        status.printJob = PrintJobInfo(name: name, progress: 0, currentLayer: 0, totalLayers: 200, elapsedTime: 0, remainingTime: 7200, filamentType: "PLA Basic", filamentColor: "Jade White")
        push()
    }
    func setNozzle(_ t: Int) { status.nozzleTargetTemp = Double(t); push() }
    func setBed(_ t: Int) { status.bedTargetTemp = Double(t); push() }
    func setSpeedLevel(_ lvl: Int) {
        let pct = [1: 50, 2: 100, 3: 124, 4: 166][lvl] ?? 100
        status.printSpeed = pct; push()
    }
    func setFlow(_ f: Int) { status.flowRate = f; push() }
    func setLight(on: Bool) { push() }
}
