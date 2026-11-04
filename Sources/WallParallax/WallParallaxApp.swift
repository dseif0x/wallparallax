import AppKit
import SwiftUI

@main
struct WallParallaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("WallParallax", systemImage: "cube.transparent") {
            SettingsView(state: AppState.shared, tracker: HeadTracker.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: WallpaperController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Snapshot.runIfRequested() { exit(0) }
        let controller = WallpaperController()
        controller.refresh()
        self.controller = controller
    }
}
