//  CameraView.swift
//  BambuController
//
//  Camera view with MJPEG stream support

import SwiftUI
import AVKit

struct CameraView: View {
    @StateObject private var cameraVM = CameraViewModel()
    @State private var showFullscreen = false

    var body: some View {
        NavigationStack {
            VStack {
                if cameraVM.isLoading {
                    ProgressView("Lade Kamera...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let image = cameraVM.currentImage {
                    // MJPEG Stream
                    GeometryReader { geometry in
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .onTapGesture {
                                showFullscreen = true
                            }
                    }
                } else if let snapshotURL = cameraVM.snapshotURL {
                    // Fallback to snapshot
                    AsyncImage(url: snapshotURL) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        case .failure:
                            CameraErrorView()
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .onTapGesture {
                        showFullscreen = true
                    }
                } else {
                    CameraNotConfiguredView()
                }
            }
            .navigationTitle("Kamera")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Snapshot aktualisieren") {
                            Task { await cameraVM.refreshSnapshot() }
                        }
                        Button("Stream neu starten") {
                            cameraVM.restartStream()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .fullScreenCover(isPresented: $showFullscreen) {
                FullscreenCameraView(image: cameraVM.currentImage, snapshotURL: cameraVM.snapshotURL)
            }
            .task {
                await cameraVM.start()
            }
        }
    }
}

@MainActor
class CameraViewModel: ObservableObject {
    @Published var currentImage: UIImage?
    @Published var snapshotURL: URL?
    @Published var isLoading = true

    private let apiService = APIService.shared
    private var streamTask: Task<Void, Never>?
    private var snapshotTimer: Timer?

    func start() async {
        snapshotURL = apiService.getCameraSnapshotURL()
        await refreshSnapshot()
        startMJPEGStream()
    }

    func refreshSnapshot() async {
        guard let url = snapshotURL else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                currentImage = image
            }
        } catch {
            print("Snapshot error: \(error)")
        }
        isLoading = false
    }

    func startMJPEGStream() {
        guard let streamURL = apiService.getCameraStreamURL() else { return }

        streamTask = Task {
            await parseMJPEGStream(from: streamURL)
        }
    }

    private func parseMJPEGStream(from url: URL) async {
        do {
            let (bytes, _) = try await URLSession.shared.bytes(from: url)
            var buffer = Data()

            for try await byte in bytes {
                buffer.append(byte)

                // Look for JPEG markers
                if buffer.count > 2,
                   buffer[buffer.count - 2] == 0xFF,
                   buffer[buffer.count - 1] == 0xD9, // End of JPEG
                   let startIndex = buffer.firstIndex(of: 0xFF) {
                    // Find start of JPEG (0xFF 0xD8)
                    var jpegStart = startIndex
                    while jpegStart < buffer.count - 1 {
                        if buffer[jpegStart] == 0xFF && buffer[jpegStart + 1] == 0xD8 {
                            break
                        }
                        jpegStart += 1
                    }

                    let jpegData = buffer[jpegStart...]
                    if let image = UIImage(data: jpegData) {
                        await MainActor.run {
                            self.currentImage = image
                        }
                    }
                    buffer.removeAll()
                }

                // Prevent buffer overflow
                if buffer.count > 1_000_000 {
                    buffer.removeAll()
                }
            }
        } catch {
            print("MJPEG stream error: \(error)")
        }
    }

    func restartStream() {
        streamTask?.cancel()
        currentImage = nil
        startMJPEGStream()
    }
}

// MARK: - Subviews

struct CameraErrorView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill.badge.exclamationmark")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("Kamera nicht erreichbar")
                .font(.headline)

            Text("Überprüfe die Kamera-Konfiguration in den Einstellungen")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CameraNotConfiguredView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.slash")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("Keine Kamera konfiguriert")
                .font(.headline)

            Text("Konfiguriere die Kamera-URL in den Einstellungen")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Camera") {
    CameraView()
}

struct FullscreenCameraView: View {
    let image: UIImage?
    let snapshotURL: URL?
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if let url = snapshotURL {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fit)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}