import Foundation
import Combine

enum SceneKind: String, CaseIterable, Identifiable {
    case mountains, space, orbs, depthPhoto, photo, layers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mountains: "Mountains at Dusk"
        case .space: "Deep Space"
        case .orbs: "Bokeh Orbs"
        case .depthPhoto: "Photo + Depth Map"
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
    @Published var depthPhotoURL: URL? { didSet { defaults.set(depthPhotoURL?.path, forKey: "depthPhotoPath") } }
    /// nil = find automatically (sibling `*_depth` file or embedded depth).
    @Published var depthMapURL: URL? { didSet { defaults.set(depthMapURL?.path, forKey: "depthMapPath") } }
    @Published var invertDepth: Bool { didSet { defaults.set(invertDepth, forKey: "invertDepth") } }
    /// Where the current depth photo's depth came from (not persisted).
    @Published var depthStatus = ""

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
            "invertDepth": false,
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
        depthPhotoURL = defaults.string(forKey: "depthPhotoPath").map { URL(fileURLWithPath: $0) }
        depthMapURL = defaults.string(forKey: "depthMapPath").map { URL(fileURLWithPath: $0) }
        invertDepth = defaults.bool(forKey: "invertDepth")
        layerURLs = (defaults.stringArray(forKey: "layerPaths") ?? []).map { URL(fileURLWithPath: $0) }
    }
}
