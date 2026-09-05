// FilesView.swift - STL import, slice profiles, job pipeline
import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @ObservedObject private var vm = FilesViewModel.shared
    @State private var showImporter = false
    @State private var profileJob: SliceJob?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    importCard
                    if vm.jobs.isEmpty && !vm.isLoading {
                        EmptyJobsView()
                    }
                    ForEach(vm.jobs) { job in
                        JobCard(job: job,
                            onSlice: { profileJob = job },
                            onPrint: { Task { await vm.print(job: job) } },
                            onDelete: { Task { await vm.delete(job: job) } })
                    }
                    Spacer(minLength: 90)
                }.padding()
            }
            .navigationTitle("Dateien")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "plus") }
                }
            }
            .task { await vm.load(); vm.startPolling() }
            .onDisappear { vm.stopPolling() }
            .refreshable { await vm.load() }
            .fileImporter(isPresented: $showImporter,
                allowedContentTypes: [.stl3D, .threemf, .obj3D, .stepFallback],
                allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    importFile(url)
                case .failure(let e):
                    vm.errorMessage = e.localizedDescription; vm.showError = true
                }
            }
            .sheet(item: $profileJob) { job in
                ProfileSheet(job: job) { params in
                    Task { await vm.slice(job: job, params: params) }
                }
            }
            .alert("Fehler", isPresented: $vm.showError, presenting: vm.errorMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { Text($0) }
        }
    }

    private var importCard: some View {
        Button { showImporter = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.plus").font(.largeTitle).foregroundColor(AppTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(vm.isUploading ? "Wird hochgeladen…" : "STL / 3MF importieren")
                        .font(.headline).foregroundColor(.primary)
                    Text("Vom iPhone zum Pi → slicen → drucken")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if vm.isUploading { ProgressView() }
                else { Image(systemName: "chevron.right").foregroundColor(.secondary) }
            }
            .padding().card()
        }
        .buttonStyle(.plain)
        .disabled(vm.isUploading)
    }

    private func importFile(_ url: URL) {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            Task { await vm.upload(data: data, filename: url.lastPathComponent) }
        } catch {
            vm.errorMessage = "Datei kann nicht gelesen werden: \(error.localizedDescription)"
            vm.showError = true
        }
    }
}

// MARK: - Subviews

private struct EmptyJobsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "cube.transparent.fill").font(.system(size: 52)).foregroundColor(.secondary)
            Text("Noch keine Dateien").font(.headline)
            Text("Tippe oben auf +, wähle eine STL- oder 3MF-Datei,\nund der Pi slicet und druckt sie.")
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
    }
}

private struct JobCard: View {
    let job: SliceJob
    let onSlice: () -> Void
    let onPrint: () -> Void
    let onDelete: () -> Void
    @State private var confirmDelete = false
    @State private var confirmPrint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: job.stage.systemImage)
                    .font(.title2).foregroundColor(stageColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.filename).font(.headline).lineLimit(1)
                    Text("\(job.sizeText) · \(job.stage.displayName)").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button(role: .destructive) { confirmDelete = true } label: {
                    Image(systemName: "trash").foregroundColor(.secondary)
                }
                .disabled(job.stage.isBusy)
            }
            if job.stage.isBusy {
                ProgressView(value: job.progress / 100)
                    .progressViewStyle(LinearProgressViewStyle(tint: AppTheme.accent))
            }
            if !job.error.isEmpty {
                Text(job.error).font(.caption).foregroundColor(.red)
            }
            if !job.gcodeName.isEmpty {
                Text("G-Code: \(job.gcodeName)").font(.caption2).foregroundColor(.secondary).monospaced()
            }
            HStack(spacing: 10) {
                if job.stage == .uploaded || job.stage == .sliced || job.stage == .failed {
                    Button("Slicen…") { onSlice() }
                        .buttonStyle(.bordered).tint(AppTheme.accent)
                        .disabled(job.stage.isBusy)
                }
                if job.stage == .sliced {
                    Button("Drucken") { confirmPrint = true }
                        .buttonStyle(.borderedProminent).tint(AppTheme.accent)
                }
            }
        }
        .padding().card()
        .confirmationDialog("Wirklich drucken?", isPresented: $confirmPrint, titleVisibility: .visible) {
            Button("Druck starten") { onPrint() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("\(job.gcodeName) wird auf den Drucker übertragen und gestartet.")
        }
        .alert("Job löschen?", isPresented: $confirmDelete) {
            Button("Abbrechen", role: .cancel) {}
            Button("Löschen", role: .destructive) { onDelete() }
        }
    }

    private var stageColor: Color {
        switch job.stage {
        case .failed: return .red
        case .sliced, .done: return AppTheme.accent
        case .printing, .slicing, .uploading, .starting: return .blue
        default: return .secondary
        }
    }
}

private struct ProfileSheet: View {
    let job: SliceJob
    let onSlice: (SliceParams) -> Void
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var files = FilesViewModel.shared
    @State private var params = SliceParams()

    var body: some View {
        NavigationStack {
            Form {
                Section("Datei") {
                    Text(job.filename).font(.headline).lineLimit(1)
                    Text(job.sizeText).font(.caption).foregroundColor(.secondary)
                }
                Section("Filament") {
                    ForEach(filamentOptions, id: \.key) { opt in
                        FilamentRow(key: opt.key, info: opt.value, selected: params.filament == opt.key) {
                            params.filament = opt.key
                        }
                    }
                }
                Section("Qualität") {
                    ForEach(qualityOptions, id: \.key) { opt in
                        QualityRow(key: opt.key, info: opt.value, selected: params.quality == opt.key) {
                            params.quality = opt.key
                        }
                    }
                }
                Section("Optionen") {
                    Toggle("Stützstruktur", isOn: $params.supports)
                    HStack {
                        Text("Infill")
                        Spacer()
                        Text("\(params.infill) %").monospacedDigit().foregroundColor(.secondary)
                    }
                    Slider(value: Binding(get: { Double(params.infill) }, set: { params.infill = Int($0) }), in: 0...100, step: 5)
                }
                Section {
                    Button("Slicen starten") { onSlice(params); dismiss() }
                        .buttonStyle(PrimaryButtonStyle())
                } footer: {
                    HintText(text: "Der Pi slicet mit Bambu-A1-Profilen (Düse max. 300 °C, Bett max. 100 °C). Je nach Modell dauert das 1–10 Minuten — der Fortschritt läuft hier live ein.")
                }
            }
            .navigationTitle("Slicen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Abbrechen") { dismiss() } } }
        }
    }

    private var filamentOptions: [(key: String, value: FilamentInfo)] {
        let defaults = ["pla": FilamentInfo(name: "PLA", nozzle: 220, bed: 65, note: nil),
                        "petg": FilamentInfo(name: "PETG", nozzle: 250, bed: 70, note: nil),
                        "tpu": FilamentInfo(name: "TPU", nozzle: 215, bed: 60, note: nil)]
        let f = files.profiles?.filaments ?? defaults
        return ["pla", "petg", "tpu"].compactMap { k in f[k].map { (k, $0) } }
    }

    private var qualityOptions: [(key: String, value: QualityInfo)] {
        let defaults = ["draft": QualityInfo(name: "Entwurf", layerMm: 0.28, note: "Schnell & grob"),
                        "standard": QualityInfo(name: "Standard", layerMm: 0.20, note: "Ausgewogen"),
                        "fine": QualityInfo(name: "Fein", layerMm: 0.12, note: "Langsam & detailliert")]
        let q = files.profiles?.qualities ?? defaults
        return ["draft", "standard", "fine"].compactMap { k in q[k].map { (k, $0) } }
    }
}

private struct FilamentRow: View {
    let key: String; let info: FilamentInfo; let selected: Bool; let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name).foregroundColor(.primary)
                    Text("\(info.nozzle)° / \(info.bed)°\(info.note.map { " · \($0)" } ?? "")")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundColor(AppTheme.accent) }
            }
        }.buttonStyle(.plain)
    }
}

private struct QualityRow: View {
    let key: String; let info: QualityInfo; let selected: Bool; let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name).foregroundColor(.primary)
                    Text(String(format: "%.2f mm · %@", info.layerMm, info.note)).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundColor(AppTheme.accent) }
            }
        }.buttonStyle(.plain)
    }
}

private extension UTType {
    static var stl3D: UTType { UTType(filenameExtension: "stl") ?? .data }
    static var threemf: UTType { UTType(filenameExtension: "3mf") ?? .data }
    static var obj3D: UTType { UTType(filenameExtension: "obj") ?? .data }
    static var stepFallback: UTType { UTType(filenameExtension: "step") ?? .data }
}

#Preview { FilesView() }
