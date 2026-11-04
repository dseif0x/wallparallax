import AppKit
import QuartzCore

/// Geometry shared by all scene builders. Layers are larger than the screen by `overscan` on every side;
/// `point(_:_:)` maps screen fractions (0...1, y up) into layer coordinates.
struct SceneContext {
    let screen: CGSize
    let overscan: CGFloat
    let scale: CGFloat

    var layerFrame: CGRect {
        CGRect(x: -overscan, y: -overscan, width: screen.width + 2 * overscan, height: screen.height + 2 * overscan)
    }
    var size: CGSize { layerFrame.size }
    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: overscan + fx * screen.width, y: overscan + fy * screen.height)
    }

    func container(depth: CGFloat) -> DepthLayer {
        let layer = CALayer()
        layer.frame = layerFrame
        layer.contentsScale = scale
        return DepthLayer(layer: layer, depth: depth)
    }

    func fullGradient(_ colors: [CGColor], locations: [NSNumber]? = nil,
                      start: CGPoint = CGPoint(x: 0.5, y: 0), end: CGPoint = CGPoint(x: 0.5, y: 1)) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.frame = bounds
        g.colors = colors
        g.locations = locations
        g.startPoint = start
        g.endPoint = end
        g.contentsScale = scale
        return g
    }

    /// A soft radial glow centered at `center` (layer coords).
    func glow(center: CGPoint, radius: CGFloat, colors: [CGColor], locations: [NSNumber]? = nil) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.type = .radial
        g.frame = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        g.colors = colors
        g.locations = locations
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 1)
        g.contentsScale = scale
        return g
    }

    func shape(_ path: CGPath, fill: CGColor) -> CAShapeLayer {
        let s = CAShapeLayer()
        s.frame = bounds
        s.path = path
        s.fillColor = fill
        s.contentsScale = scale
        return s
    }
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// Deterministic RNG so scenes look the same on every screen and launch.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Scenes {
    // MARK: Mountains

    static func mountains(_ c: SceneContext) -> [DepthLayer] {
        var rng = SplitMix64(seed: 42)
        var result: [DepthLayer] = []
        let h = c.screen.height

        // Sky
        let sky = c.container(depth: 1)
        sky.layer.addSublayer(c.fullGradient(
            [rgb(0xF7C59F), rgb(0xEF8E7D), rgb(0xA4628F), rgb(0x3F3466), rgb(0x161632)],
            locations: [0, 0.3, 0.5, 0.75, 1]))
        sky.layer.addSublayer(stars(c, count: 140, radius: 0.5...1.2, minY: 0.6, color: rgb(0xFFFFFF, 0.55), rng: &rng))
        result.append(sky)

        // Sun
        let sun = c.container(depth: 0.95)
        let sunCenter = c.point(0.66, 0.47)
        sun.layer.addSublayer(c.glow(center: sunCenter, radius: h * 0.45,
                                     colors: [rgb(0xFFE3B0, 0.75), rgb(0xFFB38A, 0.25), rgb(0xFF9A7A, 0)],
                                     locations: [0, 0.3, 1]))
        let r = h * 0.055
        sun.layer.addSublayer(c.shape(CGPath(ellipseIn: CGRect(x: sunCenter.x - r, y: sunCenter.y - r, width: 2 * r, height: 2 * r), transform: nil),
                                      fill: rgb(0xFFF1D6)))
        result.append(sun)

        // Ridges, far → near
        let ridges: [(depth: CGFloat, base: CGFloat, amp: CGFloat, color: UInt32, mist: UInt32)] = [
            (0.85, 0.36, 0.16, 0xC98A9B, 0xF2B9A0),
            (0.66, 0.30, 0.15, 0x9A6690, 0xE59A92),
            (0.47, 0.22, 0.14, 0x6A4A7E, 0xB5768C),
            (0.28, 0.13, 0.12, 0x3E3062, 0x7D5679),
            (0.08, 0.02, 0.10, 0x1B1834, 0x3E3062),
        ]
        for (i, ridge) in ridges.enumerated() {
            let container = c.container(depth: ridge.depth)
            let (path, heights) = ridgePath(c, base: ridge.base, amplitude: ridge.amp, rng: &rng)
            container.layer.addSublayer(c.shape(path, fill: rgb(ridge.color)))

            // Mist pooling in the valley at the foot of the ridge
            if i < ridges.count - 1 {
            let topOfMist = (ridge.base * h + c.overscan) / c.size.height
            container.layer.addSublayer(c.fullGradient(
                [rgb(ridge.mist, 0.75), rgb(ridge.mist, 0)],
                locations: [NSNumber(value: Double(topOfMist) * 0.6), NSNumber(value: Double(topOfMist) + 0.06)]))
            }

            if i >= ridges.count - 2 {
                container.layer.addSublayer(trees(c, heights: heights, color: rgb(ridge.color),
                                                  size: (i == ridges.count - 1 ? 0.07 : 0.035) * h, rng: &rng))
            }
            result.append(container)
        }
        return result
    }

    /// Ridged sine noise along the full layer width. Returns the filled path and the sampled heights.
    private static func ridgePath(_ c: SceneContext, base: CGFloat, amplitude: CGFloat,
                                  rng: inout SplitMix64) -> (CGPath, [(CGFloat, CGFloat)]) {
        let octaves: [(f: CGFloat, a: CGFloat, phase: CGFloat)] = (0..<5).map { i in
            (2.4 * pow(2, CGFloat(i)) * .random(in: 0.75...1.25, using: &rng),
             pow(0.5, CGFloat(i)),
             .random(in: 0...(2 * .pi), using: &rng))
        }
        let norm = octaves.reduce(0) { $0 + $1.a }
        let path = CGMutablePath()
        path.move(to: .zero)
        var samples: [(CGFloat, CGFloat)] = []
        for x in stride(from: CGFloat(0), through: c.size.width + 4, by: 4) {
            let u = (x - c.overscan) / c.screen.width
            var n: CGFloat = 0
            for o in octaves { n += o.a * (1 - abs(sin(u * o.f + o.phase))) }
            let y = c.point(0, base).y + (n / norm) * amplitude * c.screen.height
            path.addLine(to: CGPoint(x: x, y: y))
            samples.append((x, y))
        }
        path.addLine(to: CGPoint(x: c.size.width + 4, y: 0))
        path.closeSubpath()
        return (path, samples)
    }

    private static func trees(_ c: SceneContext, heights: [(CGFloat, CGFloat)], color: CGColor,
                              size: CGFloat, rng: inout SplitMix64) -> CAShapeLayer {
        let path = CGMutablePath()
        var x: CGFloat = 0
        while x < c.size.width {
            x += .random(in: size * 0.25...size * 1.6, using: &rng)
            guard let sample = heights.min(by: { abs($0.0 - x) < abs($1.0 - x) }) else { break }
            let th = size * .random(in: 0.6...1.3, using: &rng)
            let tw = th * 0.32
            let baseY = sample.1 - th * 0.15
            // Three stacked triangles: a simple pine silhouette
            for tier in 0..<3 {
                let t = CGFloat(tier)
                let y0 = baseY + th * 0.25 * t
                let w = tw * (1 - t * 0.25)
                path.move(to: CGPoint(x: x - w, y: y0))
                path.addLine(to: CGPoint(x: x + w, y: y0))
                path.addLine(to: CGPoint(x: x, y: y0 + th * 0.5))
                path.closeSubpath()
            }
        }
        return c.shape(path, fill: color)
    }

    // MARK: Space

    static func space(_ c: SceneContext) -> [DepthLayer] {
        var rng = SplitMix64(seed: 7)
        let h = c.screen.height
        var result: [DepthLayer] = []

        let back = c.container(depth: 1)
        back.layer.addSublayer(c.fullGradient([rgb(0x0B0820), rgb(0x05030F)]))
        back.layer.addSublayer(stars(c, count: 900, radius: 0.4...0.9, color: rgb(0xFFFFFF, 0.6), rng: &rng))
        result.append(back)

        let nebula = c.container(depth: 0.9)
        let nebulaColors: [UInt32] = [0x7B2FF7, 0xF72585, 0x4CC9F0, 0x3A0CA3, 0xB5179E]
        for color in nebulaColors {
            let center = c.point(.random(in: 0...1, using: &rng), .random(in: 0.2...1, using: &rng))
            nebula.layer.addSublayer(c.glow(center: center, radius: h * .random(in: 0.35...0.7, using: &rng),
                                            colors: [rgb(color, 0.3), rgb(color, 0.1), rgb(color, 0)],
                                            locations: [0, 0.5, 1]))
        }
        result.append(nebula)

        let mid = c.container(depth: 0.65)
        mid.layer.addSublayer(stars(c, count: 260, radius: 0.8...1.5, color: rgb(0xFFFFFF, 0.85), rng: &rng))
        result.append(mid)

        // Moon
        let moon = c.container(depth: 0.42)
        let mc = c.point(0.8, 0.7), mr = h * 0.045
        let moonBody = CAGradientLayer()
        moonBody.frame = CGRect(x: mc.x - mr, y: mc.y - mr, width: 2 * mr, height: 2 * mr)
        moonBody.colors = [rgb(0xF2EEE3), rgb(0x8C8880), rgb(0x2A2826)]
        moonBody.locations = [0, 0.45, 1]
        moonBody.startPoint = CGPoint(x: 0.1, y: 0.9)
        moonBody.endPoint = CGPoint(x: 0.95, y: 0.1)
        moonBody.cornerRadius = mr
        moonBody.contentsScale = c.scale
        moon.layer.addSublayer(c.glow(center: mc, radius: mr * 2.4, colors: [rgb(0xD8E6FF, 0.25), rgb(0xD8E6FF, 0)]))
        moon.layer.addSublayer(moonBody)
        result.append(moon)

        let near = c.container(depth: 0.3)
        near.layer.addSublayer(stars(c, count: 60, radius: 1.4...2.4, color: rgb(0xFFFFFF), rng: &rng))
        for _ in 0..<6 {
            let p = c.point(.random(in: 0...1, using: &rng), .random(in: 0.35...1, using: &rng))
            near.layer.addSublayer(c.glow(center: p, radius: .random(in: 10...22, using: &rng),
                                          colors: [rgb(0xFFFFFF, 0.9), rgb(0xBFD8FF, 0.3), rgb(0xBFD8FF, 0)],
                                          locations: [0, 0.2, 1]))
        }
        result.append(near)

        // Big planet rising from the bottom-left
        let planet = c.container(depth: 0.1)
        let pc = c.point(0.2, -0.32), pr = h * 0.62
        planet.layer.addSublayer(c.glow(center: pc, radius: pr * 1.12,
                                        colors: [rgb(0x6FB7FF, 0.5), rgb(0x6FB7FF, 0.5), rgb(0x6FB7FF, 0)],
                                        locations: [0, 0.88, 1]))
        let body = CAGradientLayer()
        body.frame = CGRect(x: pc.x - pr, y: pc.y - pr, width: 2 * pr, height: 2 * pr)
        body.colors = [rgb(0x8FD3FF), rgb(0x2D6AA8), rgb(0x0C1E3E), rgb(0x050A18)]
        body.locations = [0, 0.3, 0.6, 1]
        body.startPoint = CGPoint(x: 0.75, y: 1)
        body.endPoint = CGPoint(x: 0.2, y: 0.3)
        body.cornerRadius = pr
        body.contentsScale = c.scale
        planet.layer.addSublayer(body)
        result.append(planet)

        return result
    }

    // MARK: Orbs

    static func orbs(_ c: SceneContext) -> [DepthLayer] {
        var rng = SplitMix64(seed: 2024)
        let h = c.screen.height
        var result: [DepthLayer] = []

        let back = c.container(depth: 1)
        back.layer.addSublayer(c.fullGradient([rgb(0x24243E), rgb(0x302B63), rgb(0x0F0C29)],
                                              start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1)))
        result.append(back)

        let palette: [UInt32] = [0xFF6B9D, 0xC44DFF, 0x4DD8FF, 0xFFD166, 0x06D6A0, 0xFF8E5E]
        let depths = (0..<48).map { _ in CGFloat.random(in: 0.02...0.98, using: &rng) }.sorted(by: >)
        for depth in depths {
            let container = c.container(depth: depth)
            let nearness = 1 - depth
            let radius = h * (0.02 + nearness * nearness * 0.16) * .random(in: 0.7...1.3, using: &rng)
            let color = palette.randomElement(using: &rng)!
            let alpha = 0.35 + 0.35 * (1 - nearness)
            let edge = 0.85 - nearness * 0.55   // near orbs are softer (out of focus)
            let center = c.point(.random(in: -0.05...1.05, using: &rng), .random(in: -0.05...1.05, using: &rng))
            container.layer.addSublayer(c.glow(center: center, radius: radius,
                                               colors: [rgb(color, alpha), rgb(color, alpha * 0.8), rgb(color, 0)],
                                               locations: [0, NSNumber(value: Double(edge)), 1]))
            result.append(container)
        }
        return result
    }

    // MARK: Images

    static func photo(_ c: SceneContext, _ photo: PhotoProcessor.Result) -> [DepthLayer] {
        var result: [DepthLayer] = []
        let back = c.container(depth: photo.foreground == nil ? 0.5 : 0.65)
        back.layer.addSublayer(imageLayer(c, photo.background))
        result.append(back)
        if let fg = photo.foreground {
            let front = c.container(depth: 0)
            front.layer.addSublayer(imageLayer(c, fg))
            result.append(front)
        }
        return result
    }

    /// Images ordered back → front; the first gets depth 1, the last depth 0.
    static func layers(_ c: SceneContext, _ images: [CGImage]) -> [DepthLayer] {
        images.enumerated().map { i, image in
            let depth = images.count == 1 ? 0.5 : 1 - CGFloat(i) / CGFloat(images.count - 1)
            let container = c.container(depth: depth)
            container.layer.addSublayer(imageLayer(c, image))
            return container
        }
    }

    private static func imageLayer(_ c: SceneContext, _ image: CGImage) -> CALayer {
        let l = CALayer()
        l.frame = c.bounds
        l.contents = image
        l.contentsGravity = .resizeAspectFill
        l.masksToBounds = true
        l.contentsScale = c.scale
        return l
    }

    // MARK: Helpers

    private static func stars(_ c: SceneContext, count: Int, radius: ClosedRange<CGFloat>, minY: CGFloat = 0,
                              color: CGColor, rng: inout SplitMix64) -> CAShapeLayer {
        let path = CGMutablePath()
        for _ in 0..<count {
            let x = CGFloat.random(in: 0...c.size.width, using: &rng)
            let y = CGFloat.random(in: (minY * c.size.height)...c.size.height, using: &rng)
            let r = CGFloat.random(in: radius, using: &rng)
            path.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        return c.shape(path, fill: color)
    }
}
