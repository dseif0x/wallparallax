import AppKit
import QuartzCore

/// Developer aid: `WallParallax --snapshot <dir>` renders every built-in scene at a few
/// head positions to PNGs (no camera needed), then exits.
enum Snapshot {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let size = CGSize(width: 1440, height: 900)
        let poses: [(String, CGFloat, CGFloat)] = [("left", -1.2, 0), ("center", 0, 0), ("right", 1.2, 0)]
        let maxShift = min(size.width, size.height) * 0.05
        let ctx = SceneContext(screen: size, overscan: ceil(maxShift * 1.6 + size.width * 0.04 + 8), scale: 1)

        let scenes: [(String, [DepthLayer])] = [
            ("mountains", Scenes.mountains(ctx)), ("space", Scenes.space(ctx)), ("orbs", Scenes.orbs(ctx)),
        ]
        for (name, layers) in scenes {
            let root = CALayer()
            root.frame = CGRect(origin: .zero, size: size)
            root.backgroundColor = .black
            layers.forEach { root.addSublayer($0.layer) }
            for (poseName, x, z) in poses {
                for l in layers {
                    let s = 1 + z * 0.035 * (1 - l.depth)
                    l.layer.setAffineTransform(CGAffineTransform(translationX: x * maxShift * l.depth, y: 0).scaledBy(x: s, y: s))
                }
                let cg = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                root.render(in: cg)
                let rep = NSBitmapImageRep(cgImage: cg.makeImage()!)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("\(name)-\(poseName).png"))
            }
        }
        if let j = args.firstIndex(of: "--depth-photo"), j + 1 < args.count {
            let map = args.firstIndex(of: "--depth-map").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
            let key = DepthPhotoLoader.Key(image: URL(fileURLWithPath: args[j + 1]), depthMap: map, invert: false)
            if let photo = DepthPhotoLoader.shared.process(key),
               let renderer = DepthRenderer(photo: photo, screen: size, overscan: ctx.overscan, scale: 1) {
                print("depth source: \(photo.source)")
                write(photo.depth, dir.appendingPathComponent("depth-map.png"))
                for (poseName, x, z) in poses {
                    if let image = renderer.image(shift: CGPoint(x: x * maxShift, y: 0), zoom: z * 0.035) {
                        write(image, dir.appendingPathComponent("depth-\(poseName).png"))
                    }
                }
            } else {
                print("no depth map found")
            }
        }
        if let j = args.firstIndex(of: "--photo"), j + 1 < args.count,
           let result = PhotoProcessor.shared.process(URL(fileURLWithPath: args[j + 1])) {
            for (name, image) in [("photo-background", result.background), ("photo-foreground", result.foreground)] {
                guard let image else { continue }
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
        return true
    }

    private static func write(_ image: CGImage, _ url: URL) {
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
}
