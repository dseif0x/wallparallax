import CoreImage
import ImageIO
import Vision

enum ImageLoader {
    /// Decodes an image file, applying EXIF orientation and capping its size.
    static func load(_ url: URL, maxPixelSize: Int = 5120) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Turns a single photo into two depth layers: the subject (cut out with Vision)
/// and the background with the subject's hole filled in.
final class PhotoProcessor {
    static let shared = PhotoProcessor()

    struct Result {
        let background: CGImage
        let foreground: CGImage?
    }

    private var cache: (url: URL, result: Result)?
    private var pending: [URL: [(Result?) -> Void]] = [:]
    private let queue = DispatchQueue(label: "WallParallax.photo", qos: .userInitiated)
    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])

    /// Main thread in, main thread out. Concurrent requests for the same URL share one job.
    func load(_ url: URL, completion: @escaping (Result?) -> Void) {
        if let cache, cache.url == url { completion(cache.result); return }
        if pending[url] != nil { pending[url]!.append(completion); return }
        pending[url] = [completion]
        queue.async {
            let result = self.process(url)
            DispatchQueue.main.async {
                if let result { self.cache = (url, result) }
                self.pending.removeValue(forKey: url)?.forEach { $0(result) }
            }
        }
    }

    func process(_ url: URL) -> Result? {
        guard let cgImage = ImageLoader.load(url) else { return nil }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              !observation.allInstances.isEmpty,
              let maskBuffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        else {
            return Result(background: cgImage, foreground: nil)
        }

        let image = CIImage(cgImage: cgImage)
        let extent = image.extent
        let clear = CIImage(color: .clear).cropped(to: extent)
        let mask = CIImage(cvPixelBuffer: maskBuffer)

        // Subject with transparent surroundings.
        let foreground = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: mask,
        ])

        // Slightly grown mask so no subject edge pixels remain in the background.
        let longSide = max(extent.width, extent.height)
        let grown = mask
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(4, longSide * 0.008)])
            .cropped(to: extent)

        // Background with a hole where the subject was...
        var filled = clear.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: grown,
        ])
        // ...filled from the outside in with progressively wider blurs (push-pull style).
        for fraction in [0.01, 0.02, 0.04, 0.08, 0.16, 0.32] {
            let spread = filled
                .clampedToExtent()
                .applyingGaussianBlur(sigma: Double(longSide) * fraction)
                // Color filters work on un-premultiplied color, i.e. blur(rgb·a)/blur(a): the average
                // of nearby known pixels. Boost coverage so the fill becomes opaque quickly.
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 25)])
                .applyingFilter("CIColorClamp")
                .cropped(to: extent)
            filled = filled.composited(over: spread)
        }
        filled = filled.settingAlphaOne(in: extent)
        let background = filled.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: grown,
        ])

        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let bg = context.createCGImage(background, from: extent, format: .RGBA8, colorSpace: sRGB),
              let fg = context.createCGImage(foreground, from: extent, format: .RGBA8, colorSpace: sRGB)
        else { return Result(background: cgImage, foreground: nil) }
        return Result(background: bg, foreground: fg)
    }
}
