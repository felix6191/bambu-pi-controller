// CameraView.swift - Camera view with MJPEG stream support
import SwiftUI
import AVKit

struct CameraView: View {
    @StateObject private var cam = CameraViewModel()
    @State private var fullscreen = false

    var body: some View {
        NavigationStack {
            VStack {
                if cam.isLoading { ProgressView("Lade Kamera...").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let img = cam.currentImage {
                    GeometryReader { geo in
                        Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height).clipped()
                            .onTapGesture { fullscreen = true }
                    }
                } else if cam.authFailed {
                    CameraErrorView(title: "Zugriff verweigert", hint: "API-Token in Einstellungen prüfen (401).")
                } else if cam.snapshotURL != nil {
                    CameraErrorView(title: "Kamera nicht erreichbar", hint: "Stream/Snapshot prüfen — läuft der Pi, stimmt die CAMERA_URL?")
                } else { CameraNotConfiguredView() }
            }
            .navigationTitle("Kamera")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Snapshot aktualisieren") { Task { await cam.refreshSnapshot() } }
                        Button("Stream neu starten") { cam.restartStream() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .task { await cam.start() }
            .onDisappear { cam.stop() }
            .refreshable { await cam.refreshSnapshot() }
            .fullScreenCover(isPresented: $fullscreen) { FullscreenCameraView(image: cam.currentImage) }
        }
    }
}

@MainActor
class CameraViewModel: ObservableObject {
    @Published var currentImage: UIImage?
    @Published var snapshotURL: URL?
    @Published var isLoading = true
    @Published var authFailed = false

    private let api = APIService.shared
    private var streamTask: Task<Void, Never>?

    func start() async {
        snapshotURL = api.getCameraSnapshotURL()
        guard snapshotURL != nil else { isLoading = false; return }
        await refreshSnapshot()
        startMJPEGStream()
    }

    func stop() { streamTask?.cancel(); streamTask = nil }

    func refreshSnapshot() async {
        guard let url = snapshotURL else { isLoading = false; return }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 { authFailed = true; isLoading = false; return }
            authFailed = false
            if let img = UIImage(data: data) { currentImage = img }
        } catch { print("Snapshot error: \(error)") }
        isLoading = false
    }

    func startMJPEGStream() {
        guard let url = api.getCameraStreamURL() else { return }
        stop()
        streamTask = Task { await parseMJPEG(from: url) }
    }

    private func parseMJPEG(from url: URL) async {
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(from: url)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                await MainActor.run { self.authFailed = true; self.isLoading = false }
                return
            }
            var buffer = Data()
            for try await byte in bytes {
                if Task.isCancelled { return }
                buffer.append(byte)
                // Scan for complete JPEG (SOI FFD8 ... EOI FFD9)
                if buffer.count > 4,
                   buffer[buffer.count-2] == 0xFF, buffer[buffer.count-1] == 0xD9,
                   let soi = findSOI(in: buffer) {
                    let jpeg = Data(buffer[soi...])
                    if let img = UIImage(data: jpeg) {
                        await MainActor.run { self.currentImage = img; self.isLoading = false }
                    }
                    buffer.removeAll(keepingCapacity: true)
                }
                if buffer.count > 2_000_000 { buffer.removeAll(keepingCapacity: true) }
            }
        } catch is CancellationError {
            // normal on view disappear
        } catch {
            print("MJPEG error: \(error)")
        }
    }

    private func findSOI(in buffer: Data) -> Int? {
        var i = buffer.startIndex
        while i < buffer.endIndex - 1 {
            if buffer[i] == 0xFF && buffer[i + 1] == 0xD8 { return i }
            i += 1
        }
        return nil
    }

    func restartStream() { currentImage = nil; authFailed = false; startMJPEGStream() }
}

struct CameraErrorView: View {
    var title = "Kamera nicht erreichbar"
    var hint = "Prüfe Kamera-Konfiguration in Einstellungen"
    var body: some View { VStack(spacing: 16) { Image(systemName: "camera.fill.badge.exclamationmark").font(.system(size: 60)).foregroundColor(.secondary); Text(title).font(.headline); Text(hint).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
}

struct FullscreenCameraView: View {
    let image: UIImage?
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let img = image { Image(uiImage: img).resizable().aspectRatio(contentMode: .fit) }
            }
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Fertig") { dismiss() } } }
        }
    }
}

struct CameraNotConfiguredView: View {
    var body: some View { VStack(spacing: 16) { Image(systemName: "camera.slash").font(.system(size: 60)).foregroundColor(.secondary); Text("Keine Kamera konfiguriert").font(.headline); Text("Server-URL in Einstellungen eintragen").font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
}

#Preview("Camera") { CameraView() }
