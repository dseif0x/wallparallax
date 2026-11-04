import Accelerate
import AVFoundation
import CoreImage
import ImageIO

/// A color image plus a matching grayscale depth map (white = near).
struct DepthPhoto {
    enum Source: Equatable {
        case file(URL)
        case embedded
        case estimated(DepthModelKind)
    }

    let color: CGImage
    /// 8-bit grayscale, normalized to 0...1, white = near, already smoothed for rendering.
    let depth: CGImage
    let source: Source
}

/// Loads a photo and finds its depth map, in this order:
/// 1. the depth map file the user picked,
/// 2. a sibling file such as `photo_depth.png` / `photo-depth.png`,
/// 3. depth/disparity embedded in the photo (iPhone Portrait mode HEIC/JPEG),
/// 4. AI depth estimation, if the model is installed.
final class DepthPhotoLoader {
    static let shared = DepthPhotoLoader()

    struct Key: Hashable {
        let image: URL
        let depthMap: URL?
        let invert: Bool
        /// AI model to fall back to when no depth map exists.
        let model: DepthModelKind?
    }

    private var cache: (key: Key, photo: DepthPhoto)?
    private var pending: [Key: [(DepthPhoto?) -> Void]] = [:]
    private let queue = DispatchQueue(label: "WallParallax.depth", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])

    /// Main thread in, main thread out.
    func load(_ key: Key, completion: @escaping (DepthPhoto?) -> Void) {
        if let cache, cache.key == key { completion(cache.photo); return }
        if pending[key] != nil { pending[key]!.append(completion); return }
        pending[key] = [completion]
        queue.async {
            let photo = self.process(key)
            DispatchQueue.main.async {
                if let photo { self.cache = (key, photo) }
                self.pending.removeValue(forKey: key)?.forEach { $0(photo) }
            }
        }
    }

    func process(_ key: Key) -> DepthPhoto? {
        guard let color = ImageLoader.load(key.image) else { return nil }

        // The mesh is ~240 vertices wide, so the depth map doesn't need to be large.
        let longSide = 1024.0
        let s = longSide / Double(max(color.width, color.height))
        let width = max(2, Int((Double(color.width) * s).rounded()))
        let height = max(2, Int((Double(color.height) * s).rounded()))

        var source: DepthPhoto.Source
        var raw: CGImage
        if let url = key.depthMap ?? Self.siblingDepthMap(for: key.image), let map = ImageLoader.load(url) {
            raw = map
            source = .file(url)
        } else if let embedded = Self.embeddedDepth(in: key.image) {
            raw = embedded
            source = .embedded
        } else if let kind = key.model,
                  let estimated = DepthModel.model(for: kind).estimateDepth(for: color, cacheKey: DepthModel.cacheKey(for: key.image)) {
            raw = estimated
            source = .estimated(kind)
        } else {
            return nil
        }

        // Grayscale at the working size (also stretches the map to the photo's aspect ratio).
        var bytes = Self.luminance(of: raw, width: width, height: height)
        Self.normalize(&bytes, invert: key.invert)
        guard let normalized = Self.grayImage(bytes, width: width, height: height),
              let smoothed = smooth(normalized, width: width, height: height)
        else { return nil }
        return DepthPhoto(color: color, depth: smoothed, source: source)
    }

    /// Grows near regions slightly and blurs, so depth edges stretch the background
    /// (which looks natural) instead of tearing the foreground.
    private func smooth(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let longSide = Double(max(width, height))
        let processed = CIImage(cgImage: image)
            .clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: longSide * 0.006])
            .applyingGaussianBlur(sigma: longSide * 0.005)
            .cropped(to: extent)
        guard let rgba = context.createCGImage(processed, from: extent) else { return nil }
        return Self.grayImage(Self.luminance(of: rgba, width: width, height: height), width: width, height: height)
    }

    // MARK: Depth sources

    static func siblingDepthMap(for image: URL) -> URL? {
        let base = image.deletingPathExtension().lastPathComponent.lowercased()
        let candidates = Set(["_depth", "-depth", " depth", ".depth", "_depthmap", "-depthmap", "_disparity"].map { base + $0 })
        let dir = image.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.first { candidates.contains($0.deletingPathExtension().lastPathComponent.lowercased()) }
    }

    /// Disparity or depth stored as auxiliary data (iPhone Portrait photos), as a white = near gray image.
    static func embeddedDepth(in url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        for type in [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth] {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [AnyHashable: Any],
                  var data = try? AVDepthData(fromDictionaryRepresentation: info)
            else { continue }
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let raw = props[kCGImagePropertyOrientation] as? UInt32,
               let orientation = CGImagePropertyOrientation(rawValue: raw) {
                data = data.applyingExifOrientation(orientation)
            }
            // Disparity (1/distance) is larger for near things: exactly "white = near".
            data = data.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
            if let image = grayImage(fromFloatBuffer: data.depthDataMap) { return image }
        }
        return nil
    }

    // MARK: Pixel helpers

    static func luminance(of image: CGImage, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    static func normalize(_ bytes: inout [UInt8], invert: Bool) {
        guard let lo = bytes.min(), let hi = bytes.max() else { return }
        let range = max(1, Int(hi) - Int(lo))
        for i in bytes.indices {
            let v = (Int(bytes[i]) - Int(lo)) * 255 / range
            bytes[i] = UInt8(invert ? 255 - v : v)
        }
    }

    static func grayImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func grayImage(fromFloatBuffer buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        let format = CVPixelBufferGetPixelFormatType(buffer)
        let isByte = format == kCVPixelFormatType_OneComponent8
        let isHalf = [kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DisparityFloat16,
                      kCVPixelFormatType_DepthFloat16].contains(format)

        var values = [Float](repeating: 0, count: width * height)
        values.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                let row = base + y * rowBytes
                let dst = out.baseAddress! + y * width
                if isByte {
                    let src = row.assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width { dst[x] = Float(src[x]) }
                } else if isHalf {
                    var src = vImage_Buffer(data: row, height: 1, width: vImagePixelCount(width), rowBytes: width * 2)
                    var dstBuf = vImage_Buffer(data: dst, height: 1, width: vImagePixelCount(width), rowBytes: width * 4)
                    vImageConvert_Planar16FtoPlanarF(&src, &dstBuf, 0)
                } else {
                    dst.update(from: row.assumingMemoryBound(to: Float.self), count: width)
                }
            }
        }
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for v in values where v.isFinite {
            lo = min(lo, v)
            hi = max(hi, v)
        }
        guard hi > lo else { return nil }
        let bytes = values.map { v -> UInt8 in
            v.isFinite ? UInt8(max(0, min(255, (v - lo) / (hi - lo) * 255))) : 0
        }
        return grayImage(bytes, width: width, height: height)
    }
}
