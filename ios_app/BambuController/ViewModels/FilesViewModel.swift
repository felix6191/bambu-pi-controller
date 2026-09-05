// FilesViewModel.swift - Upload / slice / print pipeline state
import Foundation
import Combine

@MainActor
class FilesViewModel: ObservableObject {
    static let shared = FilesViewModel()

    @Published var jobs: [SliceJob] = []
    @Published var profiles: ProfilesResponse?
    @Published var isLoading = false
    @Published var isUploading = false
    @Published var errorMessage: String?
    @Published var showError = false

    private let api = APIService.shared
    private var pollTask: Task<Void, Never>?
    /// Jobs mit „Sofort drucken": sobald gesliced, automatisch starten.
    private var autoPrint: Set<String> = []

    private init() {
        WebSocketService.shared.onJob = { [weak self] job in
            self?.upsert(job)
        }
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription; showError = true
    }

    private func upsert(_ job: SliceJob) {
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job }
        else { jobs.insert(job, at: 0) }
        // Sofort-Druck: Profil war vorausgewählt, User will nur noch drucken
        if job.stage == .sliced && autoPrint.contains(job.id) {
            autoPrint.remove(job.id)
            Task { await self.print(job: job) }
        }
    }

    func startPolling() {
        stopPolling()
        pollTask = Task {
            while !Task.isCancelled {
                await loadQuiet()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    func load() async {
        isLoading = true
        do {
            jobs = try await api.listJobs()
            if profiles == nil { profiles = try? await api.getProfiles() }
        } catch { fail(error) }
        isLoading = false
    }

    func loadQuiet() async {
        if let list = try? await api.listJobs() { jobs = list }
    }

    func upload(data: Data, filename: String) async {
        isUploading = true
        defer { isUploading = false }
        do {
            let job = try await api.uploadFile(data: data, filename: filename)
            upsert(job)
        } catch { fail(error) }
    }

    func slice(job: SliceJob, params: SliceParams, autoPrint: Bool = false) async {
        do {
            if autoPrint { self.autoPrint.insert(job.id) }
            upsert(try await api.sliceJob(id: job.id, params: params))
        } catch { fail(error) }
    }

    func print(job: SliceJob) async {
        do {
            upsert(try await api.printJob(id: job.id))
        } catch { fail(error) }
    }

    func delete(job: SliceJob) async {
        do {
            _ = try await api.deleteJob(id: job.id)
            jobs.removeAll { $0.id == job.id }
        } catch { fail(error) }
    }
}
