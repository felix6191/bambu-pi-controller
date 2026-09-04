// AppState.swift - Global app state
import Foundation
import SwiftUI
import Combine

class AppState: ObservableObject {
    static let shared = AppState()
    @Published var isActive = false
    @Published var needsRefresh = false
    private var bag = Set<AnyCancellable>()

    private init() {
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.handleActive() }.store(in: &bag)
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.handleBackground() }.store(in: &bag)
    }

    private func handleActive() { isActive = true; WebSocketService.shared.handleAppActive(); needsRefresh = true }
    private func handleBackground() { isActive = false; WebSocketService.shared.handleAppBackground() }
}