import Combine
import CoreML
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Vision

enum DepthModelKind: String, CaseIterable, Identifiable {
    /// Apple's Core ML build of Depth Anything V2 Small (Apache-2.0). Small and fast, softer edges.
    case depthAnything
    /// Apple's Depth Pro, Core ML conversion by Hugging Face (Apple research license, non-commercial).
    /// Much larger and slower, but with sharp object boundaries.
    case depthPro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .depthAnything: "Standard (Depth Anything V2)"
        case .depthPro: "High quality (Apple Depth Pro)"
        }
    }

    var downloadSize: String {
        switch self {
        case .depthAnything: "48 MB"
        case .depthPro: "744 MB"
        }
    }

    fileprivate var packageName: String {
        switch self {
        case .depthAnything: "DepthAnythingV2SmallF16"
        case .depthPro: "DepthProNormalizedInverseDepthPruned10QuantizedLinear"
        }
    }

    fileprivate var remoteBase: URL {
        let repo = switch self {
        case .depthAnything: "apple/coreml-depth-anything-v2-small"
        case .depthPro: "coreml-projects/DepthPro-coreml-normalized-inverse-depth-pruned-10-quantized-linear"
        }
        return URL(string: "https://huggingface.co/\(repo)/resolve/main/\(packageName).mlpackage/")!
    }
}

/// On-device monocular depth estimation. Each model is downloaded once on request and
/// compiled into Application Support. Both models output relative inverse depth (larger = nearer).
final class DepthModel: ObservableObject {
    static let depthAnything = DepthModel(kind: .depthAnything)
    static let depthPro = DepthModel(kind: .depthPro)

    static func model(for kind: DepthModelKind) -> DepthModel {
        switch kind {
        case .depthAnything: depthAnything
        case .depthPro: depthPro
        }
    }

    /// The model to use: the preferred one if installed, otherwise any installed model.
    static func best(preferring kind: DepthModelKind) -> DepthModel? {
        let preferred = model(for: kind)
        if preferred.isReady { return preferred }
        return DepthModelKind.allCases.map(model(for:)).first { $0.isReady }
    }

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case compiling
        case ready
        case failed(String)
    }

    let kind: DepthModelKind
    @Published private(set) var state: State

    private static let files = [
        "Manifest.json",
        "Data/com.apple.CoreML/model.mlmodel",
        "Data/com.apple.CoreML/weights/weight.bin",
    ]

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WallParallax", isDirectory: true)
    }
    var compiledURL: URL { Self.directory.appendingPathComponent("\(kind.packageName).mlmodelc", isDirectory: true) }
    var isReady: Bool { FileManager.default.fileExists(atPath: compiledURL.path) }

    private let inferenceLock = NSLock()
    private var progressObservation: NSKeyValueObservation?

    private init(kind: DepthModelKind) {
        self.kind = kind
        state = .notInstalled
        if isReady { state = .ready }
    }

    // MARK: Install

    func install() async {
        if case .downloading = state { return }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("WallParallax-\(UUID().uuidString)", isDirectory: true)
        let package = staging.appendingPathComponent("\(kind.packageName).mlpackage", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            setState(.downloading(0))
            for (index, file) in Self.files.enumerated() {
                let destination = package.appendingPathComponent(file)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Only the weights are big; report their progress.
                let isWeights = index == Self.files.count - 1
                try await download(kind.remoteBase.appendingPathComponent(file), to: destination,
                                   progress: isWeights ? { [weak self] in self?.setState(.downloading($0)) } : nil)
            }

            setState(.compiling)
            let compiled = try await MLModel.compileModel(at: package)
            try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try? fm.removeItem(at: compiledURL)
            try fm.moveItem(at: compiled, to: compiledURL)
            // Loading once makes macOS build and cache the hardware-specific version now (minutes for
            // Depth Pro) instead of during the first photo, where it would look like a hang.
            autoreleasepool {
                let config = MLModelConfiguration()
                config.computeUnits = .all
                _ = try? MLModel(contentsOf: compiledURL, configuration: config)
            }
            setState(.ready)
        } catch {
            setState(.failed(error.localizedDescription))
        }
    }

    private func download(_ url: URL, to destination: URL, progress: ((Double) -> Void)?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { temp, response, error in
                do {
                    if let error { throw error }
                    guard let temp, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw NSError(domain: "WallParallax", code: 1, userInfo: [NSLocalizedDescriptionKey:
                            "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(url.lastPathComponent)"])
                    }
                    // The temp file is deleted when this handler returns, so move it now.
                    try FileManager.default.moveItem(at: temp, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            if let progress {
                progressObservation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            }
            task.resume()
        }
        progressObservation = nil
    }

    private func setState(_ newState: State) {
        DispatchQueue.main.async { self.state = newState }
    }

    // MARK: Inference (call off the main thread)

    /// Relative depth as a grayscale image (white = near), or nil on failure.
    /// Results are cached on disk per photo + model, so this is slow only the first time.
    func estimateDepth(for image: CGImage, cacheKey: String) -> CGImage? {
        let cacheURL = Self.directory.appendingPathComponent("DepthCache", isDirectory: true)
            .appendingPathComponent("\(kind.rawValue)-\(cacheKey).png")
        if let cached = ImageLoader.load(cacheURL) { return cached }

        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        guard isReady else { return nil }
        // Load per use rather than keeping it resident: Depth Pro alone would pin ~1 GB of RAM.
        let result: CGImage? = autoreleasepool {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let model = try VNCoreMLModel(for: MLModel(contentsOf: compiledURL, configuration: config))
                let request = VNCoreMLRequest(model: model)
                request.imageCropAndScaleOption = .scaleFill   // both models expect a stretched, fixed-size input
                try VNImageRequestHandler(cgImage: image).perform([request])
                guard let buffer = (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer else { return nil }
                return DepthPhotoLoader.grayImage(fromFloatBuffer: buffer)
            } catch {
                NSLog("WallParallax: depth estimation with \(kind.rawValue) failed: \(error)")
                return nil
            }
        }
        if let result { Self.writePNG(result, to: cacheURL) }
        return result
    }

    /// Stable key for a photo file: path + modification date + size.
    static func cacheKey(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let raw = "\(url.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
        return SHA256.hash(data: Data(raw.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
