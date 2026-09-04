//  AppState.swift
//  BambuController
//
//  Global app state

import Foundation
import SwiftUI
import Combine

class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isActive = false
    @Published var needsRefresh = false

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Observe app lifecycle
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.handleAppActive()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                self?.handleAppBackground()
            }
            .store(in: &cancellables)
    }

    private func handleAppActive() {
        isActive = true
        WebSocketService.shared.handleAppActive()
        needsRefresh = true
    }

    private func handleAppBackground() {
        isActive = false
        WebSocketService.shared.handleAppBackground()
    }
}