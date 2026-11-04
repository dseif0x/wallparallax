import AppKit
import Combine

/// Owns the per-screen wallpaper windows and starts/stops tracking.
final class WallpaperController {
    private let state = AppState.shared
    private let tracker = HeadTracker.shared
    private var windows: [WallpaperWindow] = []
    private var bag = Set<AnyCancellable>()
    private var screensAsleep = false
    private var sessionLocked = false

    init() {
        tracker.smoothing = state.smoothing
        tracker.invertHorizontal = state.invertHorizontal
        tracker.autoRecenter = state.autoRecenter

        state.$smoothing.sink { [tracker] in tracker.smoothing = $0 }.store(in: &bag)
        state.$invertHorizontal.sink { [tracker] in tracker.invertHorizontal = $0 }.store(in: &bag)
        state.$autoRecenter.sink { [tracker] in tracker.autoRecenter = $0 }.store(in: &bag)

        state.$enabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)

        Publishers.MergeMany(
            state.$scene.map { _ in () }.eraseToAnyPublisher(),
            state.$intensity.map { _ in () }.eraseToAnyPublisher(),
            state.$photoURL.map { _ in () }.eraseToAnyPublisher(),
            state.$layerURLs.map { _ in () }.eraseToAnyPublisher(),
            state.$depthPhotoURL.map { _ in () }.eraseToAnyPublisher(),
            state.$depthMapURL.map { _ in () }.eraseToAnyPublisher(),
            state.$invertDepth.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(7)
        .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
        .sink { [weak self] in self?.windows.forEach { $0.parallaxView.rebuild() } }
        .store(in: &bag)

        // Re-render depth photos once the AI model finishes installing.
        DepthModel.shared.$state
            .dropFirst()
            .filter { $0 == .ready }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.state.scene == .depthPhoto else { return }
                self.windows.forEach { $0.parallaxView.rebuild() }
            }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.recreateWindows() }
            .store(in: &bag)

        // Don't keep the camera on while nobody can see the wallpaper.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { [weak self] _ in self?.screensAsleep = true; self?.updateTracking() }.store(in: &bag)
        workspace.publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in self?.screensAsleep = false; self?.updateTracking() }.store(in: &bag)
        let distributed = DistributedNotificationCenter.default()
        distributed.publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sessionLocked = true; self?.updateTracking() }.store(in: &bag)
        distributed.publisher(for: Notification.Name("com.apple.screenIsUnlocked"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sessionLocked = false; self?.updateTracking() }.store(in: &bag)
    }

    func refresh() {
        if state.enabled {
            if windows.isEmpty { createWindows() }
        } else {
            closeWindows()
        }
        updateTracking()
    }

    private func updateTracking() {
        if state.enabled && !screensAsleep && !sessionLocked {
            tracker.start()
        } else {
            tracker.stop()
        }
    }

    private func createWindows() {
        windows = NSScreen.screens.map { screen in
            let window = WallpaperWindow(screen: screen)
            window.orderFrontRegardless()
            return window
        }
    }

    private func closeWindows() {
        windows.forEach {
            $0.parallaxView.teardown()
            $0.close()
        }
        windows.removeAll()
    }

    private func recreateWindows() {
        closeWindows()
        if state.enabled { createWindows() }
    }
}
