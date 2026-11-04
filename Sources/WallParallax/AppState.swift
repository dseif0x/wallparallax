import Foundation
import Combine

enum SceneKind: String, CaseIterable, Identifiable {
    case mountains, space, orbs, photo, layers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mountains: "Mountains at Dusk"
        case .space: "Deep Space"
        case .orbs: "Bokeh Orbs"
        case .photo: "Photo (auto 3D)"
        case .layers: "Custom Layers"
        }
    }
}

/// User settings, persisted in UserDefaults.
final class AppState: ObservableObject {
    static let shared = AppState()
    private let defaults = UserDefaults.standard

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled") } }
    @Published var scene: SceneKind { didSet { defaults.set(scene.rawValue, forKey: "scene") } }
    /// Overall parallax strength, 0...2.
    @Published var intensity: Double { didSet { defaults.set(intensity, forKey: "intensity") } }
    /// 0 = raw/jittery, 1 = very smooth/laggy.
    @Published var smoothing: Double { didSet { defaults.set(smoothing, forKey: "smoothing") } }
    @Published var depthZoom: Bool { didSet { defaults.set(depthZoom, forKey: "depthZoom") } }
    @Published var invertHorizontal: Bool { didSet { defaults.set(invertHorizontal, forKey: "invertHorizontal") } }
    @Published var reverseParallax: Bool { didSet { defaults.set(reverseParallax, forKey: "reverseParallax") } }
    @Published var autoRecenter: Bool { didSet { defaults.set(autoRecenter, forKey: "autoRecenter") } }
    @Published var photoURL: URL? { didSet { defaults.set(photoURL?.path, forKey: "photoPath") } }
    @Published var layerURLs: [URL] { didSet { defaults.set(layerURLs.map(\.path), forKey: "layerPaths") } }

    private init() {
        defaults.register(defaults: [
            "enabled": true,
            "scene": SceneKind.mountains.rawValue,
            "intensity": 1.0,
            "smoothing": 0.5,
            "depthZoom": true,
            "invertHorizontal": false,
            "reverseParallax": false,
            "autoRecenter": true,
        ])
        enabled = defaults.bool(forKey: "enabled")
        scene = SceneKind(rawValue: defaults.string(forKey: "scene") ?? "") ?? .mountains
        intensity = defaults.double(forKey: "intensity")
        smoothing = defaults.double(forKey: "smoothing")
        depthZoom = defaults.bool(forKey: "depthZoom")
        invertHorizontal = defaults.bool(forKey: "invertHorizontal")
        reverseParallax = defaults.bool(forKey: "reverseParallax")
        autoRecenter = defaults.bool(forKey: "autoRecenter")
        photoURL = defaults.string(forKey: "photoPath").map { URL(fileURLWithPath: $0) }
        layerURLs = (defaults.stringArray(forKey: "layerPaths") ?? []).map { URL(fileURLWithPath: $0) }
    }
}
