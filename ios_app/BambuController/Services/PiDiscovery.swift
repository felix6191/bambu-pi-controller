// PiDiscovery.swift - Findet den Pi ohne IP-Eingabe (Bonjour/mDNS).
// Der Pi meldet sich per `_bambu-pi._tcp` (Avahi, richtet install.sh ein).
import Foundation
import Combine

struct DiscoveredPi: Identifiable, Equatable {
    let id: String       // pi_id, z. B. "Bambu-Pi-AB12"
    let name: String     // Anzeigename
    let baseURL: String  // http://....local:8000 oder IP
    let paired: Bool     // schon vergeben? (trotzdem wählbar -> Hinweis)
}

@MainActor
class PiDiscovery: NSObject, ObservableObject {
    static let shared = PiDiscovery()

    @Published private(set) var pis: [DiscoveredPi] = []
    @Published private(set) var searching = false

    private var browser: NetServiceBrowser?
    private var resolving: [NetService] = []
    private var known: [String: DiscoveredPi] = [:]
    private var searchTask: Task<Void, Never>?

    private override init() { super.init() }

    func start() {
        stop()
        known = [:]; pis = []
        searching = true
        let b = NetServiceBrowser()
        b.delegate = self
        browser = b
        b.searchForServices(ofType: "_bambu-pi._tcp.", inDomain: "local.")
        // Auto-Stopp nach 20 s (Batterie + klare UX)
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await MainActor.run { self.stop() }
        }
    }

    func stop() {
        searchTask?.cancel(); searchTask = nil
        browser?.stop(); browser = nil
        resolving.removeAll()
        searching = false
    }

    private func found(service: NetService) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 8)
    }

    private func publish() {
        pis = known.values.sorted { $0.name < $1.name }
    }
}

extension PiDiscovery: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(_ b: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in self.found(service: service) }
    }
    nonisolated func netServiceBrowser(_ b: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        Task { @MainActor in
            self.known = self.known.filter { $0.value.name != service.name }
            self.publish()
        }
    }
}

extension PiDiscovery: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in self.resolved(sender) }
    }
    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        Task { @MainActor in
            self.resolving.removeAll { $0 == sender }
        }
    }

    @MainActor
    private func resolved(_ service: NetService) {
        resolving.removeAll { $0 == service }
        guard let host = service.hostName, !host.isEmpty else { return }
        let base = "http://\(host):8000"
        // paired-Status + pi_id direkt vom Pi holen (offen, ohne Token)
        Task {
            let info = try? await APIService.shared.pairingStatus(baseURL: base)
            let key = info?.piId ?? service.name
            self.known[key] = DiscoveredPi(
                id: info?.piId ?? service.name,
                name: service.name.hasSuffix(".") ? String(service.name.dropLast()) : service.name,
                baseURL: base,
                paired: info?.paired ?? false
            )
            self.publish()
        }
    }
}
