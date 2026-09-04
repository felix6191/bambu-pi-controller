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
                    GeometryReader { geo in Image(uiImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: geo.size.width, height: geo.size.height).clipped().onTapGesture { fullscreen = true } }
                } else if let url = cam.snapshotURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty: ProgressView()
                        case .success(let img): img.resizable().aspectRatio(contentMode: .fit)
                        case .failure: CameraErrorView()
                        @unknown default: EmptyView()
                        }
                    }.onTapGesture { fullscreen = true }
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
            .fullScreenCover(isPresented: $fullscreen) { FullscreenCameraView(image: cam.currentImage, snapshotURL: cam.snapshotURL) }
            .task { await cam.start() }
        }
    }
}

@MainActor
class CameraViewModel: ObservableObject {
    @Published var currentImage: UIImage?
    @Published var snapshotURL: URL?
    @Published var isLoading = true

    private let api = APIService.shared
    private var streamTask: Task<Void, Never>?

    func start() async {
        snapshotURL = api.getCameraSnapshotURL()
        await refreshSnapshot()
        startMJPEGStream()
    }

    func refreshSnapshot() async {
        guard let url = snapshotURL else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let img = UIImage(data: data) { currentImage = img }
        } catch { print("Snapshot error: \(error)") }
        isLoading = false
    }

    func startMJPEGStream() {
        guard let url = api.getCameraStreamURL() else { return }
        streamTask = Task { await parseMJPEG(from: url) }
    }

    private func parseMJPEG(from url: URL) async {
        do {
            let (bytes, _) = try await URLSession.shared.bytes(from: url)
            var buffer = Data()
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count > 2, buffer[buffer.count-2] == 0xFF, buffer[buffer.count-1] == 0xD9,
                   let start = buffer.firstIndex(of: 0xFF) {
                    var jpegStart = start
                    while jpegStart < buffer.count - 1 {
                        if buffer[jpegStart] == 0xFF && buffer[jpegStart+1] == 0xD8 { break }
                        jpegStart += 1
                    }
                    if let img = UIImage(data: buffer[jpegStart...]) { await MainActor.run { self.currentImage = img } }
                    buffer.removeAll()
                }
                if buffer.count > 1_000_000 { buffer.removeAll() }
            }
        } catch { print("MJPEG error: \(error)") }
    }

    func restartStream() { streamTask?.cancel(); currentImage = nil; startMJPEGStream() }
}

struct CameraErrorView: View {
    var body: some View { VStack(spacing: 16) { Image(systemName: "camera.fill.badge.exclamationmark").font(.system(size: 60)).foregroundColor(.secondary); Text("Kamera nicht erreichbar").font(.headline); Text("Prüfe Kamera-Konfiguration in Einstellungen").font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
}

struct CameraNotConfiguredView: View {
    var body: some View { VStack(spacing: 16) { Image(systemName: "camera.slash").font(.system(size: 60)).foregroundColor(.secondary); Text("Keine Kamera konfiguriert").font(.headline); Text("Konfiguriere Kamera-URL in Einstellungen").font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
}

struct FullscreenCameraView: View {
    let image: UIImage?; let snapshotURL: URL?
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            ZStack { Color.black.ignoresSafeArea()
                if let img = image { Image(uiImage: img).resizable().aspectRatio(contentMode: .fit) }
                else if let url = snapshotURL { AsyncImage(url: url) { if case .success(let img) = $0 { img.resizable().aspectRatio(contentMode: .fit) } } }
            }.toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Fertig") { dismiss() } } }
        }
    }
}

#Preview("Camera") { CameraView() }