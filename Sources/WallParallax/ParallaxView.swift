import AppKit
import QuartzCore

/// A full-screen layer that moves according to its depth.
/// depth 1 = far away (moves the most with your head), 0 = at the screen plane (fixed).
struct DepthLayer {
    let layer: CALayer
    let depth: CGFloat
}

/// Hosts the depth layers of a scene and moves them every display frame.
final class ParallaxView: NSView {
    private let state = AppState.shared
    private let tracker = HeadTracker.shared

    private var depthLayers: [DepthLayer] = []
    private var depthRenderer: DepthRenderer?
    private var link: CADisplayLink?
    private var current = HeadPose()
    private var lastTimestamp: CFTimeInterval = 0
    private var maxShift: CGFloat = 0
    private var buildToken = 0
    private var builtSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        rebuild()
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if window != nil, newSize != builtSize { rebuild() }
    }

    func teardown() {
        link?.invalidate()
        link = nil
    }

    // MARK: Scene building

    func rebuild() {
        guard let window, bounds.width > 0, bounds.height > 0 else { return }
        buildToken += 1
        let token = buildToken
        let size = bounds.size
        builtSize = size

        maxShift = CGFloat(state.intensity) * min(size.width, size.height) * 0.05
        // Enough slack that layers never reveal their edges when shifted or scaled.
        let overscan = ceil(maxShift * 1.6 + max(size.width, size.height) * 0.04 + 8)
        let ctx = SceneContext(screen: size, overscan: overscan, scale: window.backingScaleFactor)

        switch state.scene {
        case .mountains: install(Scenes.mountains(ctx))
        case .space: install(Scenes.space(ctx))
        case .orbs: install(Scenes.orbs(ctx))
        case .photo:
            guard let url = state.photoURL else { install(Scenes.mountains(ctx)); return }
            installSubjectPhoto(url, ctx: ctx, token: token)
        case .depthPhoto:
            guard let url = state.depthPhotoURL else { install(Scenes.mountains(ctx)); return }
            let key = DepthPhotoLoader.Key(image: url, depthMap: state.depthMapURL, invert: state.invertDepth)
            DepthPhotoLoader.shared.load(key) { [weak self] photo in
                guard let self, self.buildToken == token else { return }
                if let photo, let renderer = DepthRenderer(photo: photo, screen: ctx.screen,
                                                           overscan: ctx.overscan, scale: ctx.scale) {
                    self.install([], renderer: renderer)
                } else {
                    // No depth map found: fall back to the Vision subject cut-out.
                    self.installSubjectPhoto(url, ctx: ctx, token: token)
                }
            }
        case .layers:
            let images = state.layerURLs.compactMap { ImageLoader.load($0) }
            install(images.isEmpty ? Scenes.mountains(ctx) : Scenes.layers(ctx, images))
        }
    }

    private func installSubjectPhoto(_ url: URL, ctx: SceneContext, token: Int) {
        PhotoProcessor.shared.load(url) { [weak self] result in
            guard let self, self.buildToken == token else { return }
            self.install(result.map { Scenes.photo(ctx, $0) } ?? Scenes.mountains(ctx))
        }
    }

    private func install(_ newLayers: [DepthLayer], renderer: DepthRenderer? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        depthLayers.forEach { $0.layer.removeFromSuperlayer() }
        depthRenderer?.layer.removeFromSuperlayer()
        depthLayers = newLayers
        depthRenderer = renderer
        newLayers.forEach { layer?.addSublayer($0.layer) }
        if let renderer { layer?.addSublayer(renderer.layer) }
        CATransaction.commit()
        apply()
    }

    // MARK: Animation

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTimestamp == 0 ? 1.0 / 60 : min(0.1, max(0, now - lastTimestamp))
        lastTimestamp = now

        let visible = tracker.faceVisible
        let target = visible ? tracker.pose : .zero
        // Interpolate camera samples (~30 Hz) up to display rate; drift home slowly when the face is lost.
        let k = 1 - exp(-dt * (visible ? 16 : 2))
        let next = HeadPose(
            x: current.x + (target.x - current.x) * k,
            y: current.y + (target.y - current.y) * k,
            z: current.z + (target.z - current.z) * k
        )
        let delta = abs(next.x - current.x) + abs(next.y - current.y) + abs(next.z - current.z)
        current = next
        if delta > 0.00005 { apply() }
    }

    private func apply() {
        let direction: CGFloat = state.reverseParallax ? -1 : 1
        let zoom = state.depthZoom
        let x = CGFloat(current.x), y = CGFloat(current.y), z = CGFloat(current.z)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in depthLayers {
            let dx = x * maxShift * item.depth * direction
            let dy = y * maxShift * item.depth * direction * 0.75
            // Leaning in makes nearer layers grow more than distant ones.
            let s = zoom ? 1 + z * 0.035 * (1 - item.depth) : 1
            item.layer.setAffineTransform(CGAffineTransform(translationX: dx, y: dy).scaledBy(x: s, y: s))
        }
        CATransaction.commit()

        depthRenderer?.draw(shift: CGPoint(x: x * maxShift * direction, y: y * maxShift * direction * 0.75),
                            zoom: zoom ? z * 0.035 : 0)
    }
}

/// Borderless window that sits at desktop level (above the system wallpaper, below desktop icons).
final class WallpaperWindow: NSWindow {
    let parallaxView: ParallaxView

    init(screen: NSScreen) {
        parallaxView = ParallaxView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        contentView = parallaxView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
