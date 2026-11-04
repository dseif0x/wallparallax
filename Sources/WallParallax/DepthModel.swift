import Combine
import CoreML
import Vision

/// On-device monocular depth estimation with Apple's Core ML build of Depth Anything V2 (Small, Apache-2.0).
/// The model (~48 MB) is downloaded once on request and compiled into Application Support.
final class DepthModel: ObservableObject {
    static let shared = DepthModel()

    enum State: Equatable {
        case notInstalled, downloading, compiling, ready
        case failed(String)
    }

    @Published private(set) var state: State

    private static let name = "DepthAnythingV2SmallF16"
    private static let remoteBase = URL(string:
        "https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main/\(name).mlpackage/")!
    private static let files = [
        "Manifest.json",
        "Data/com.apple.CoreML/model.mlmodel",
        "Data/com.apple.CoreML/weights/weight.bin",
    ]

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WallParallax", isDirectory: true)
    }
    static var compiledURL: URL { directory.appendingPathComponent("\(name).mlmodelc", isDirectory: true) }

    var isReady: Bool { FileManager.default.fileExists(atPath: Self.compiledURL.path) }

    private var visionModel: VNCoreMLModel?
    private let lock = NSLock()

    private init() {
        state = FileManager.default.fileExists(atPath: Self.compiledURL.path) ? .ready : .notInstalled
    }

    // MARK: Install

    func install() async {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("WallParallax-\(UUID().uuidString)", isDirectory: true)
        let package = staging.appendingPathComponent("\(Self.name).mlpackage", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            setState(.downloading)
            for file in Self.files {
                let (temp, response) = try await URLSession.shared.download(from: Self.remoteBase.appendingPathComponent(file))
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw NSError(domain: "WallParallax", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(file)"])
                }
                let destination = package.appendingPathComponent(file)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: temp, to: destination)
            }

            setState(.compiling)
            let compiled = try await MLModel.compileModel(at: package)
            try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try? fm.removeItem(at: Self.compiledURL)
            try fm.moveItem(at: compiled, to: Self.compiledURL)
            setState(.ready)
        } catch {
            setState(.failed(error.localizedDescription))
        }
    }

    private func setState(_ newState: State) {
        DispatchQueue.main.async { self.state = newState }
    }

    // MARK: Inference (call off the main thread)

    /// Relative depth as a grayscale image (white = near), or nil if the model isn't installed.
    func estimateDepth(for image: CGImage) -> CGImage? {
        guard let model = loadModel() else { return nil }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill   // the model was evaluated on stretched input
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            NSLog("WallParallax: depth estimation failed: \(error)")
            return nil
        }
        guard let buffer = (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer else { return nil }
        // Depth Anything outputs relative inverse depth: larger = nearer.
        return DepthPhotoLoader.grayImage(fromFloatBuffer: buffer)
    }

    private func loadModel() -> VNCoreMLModel? {
        lock.lock()
        defer { lock.unlock() }
        if let visionModel { return visionModel }
        guard isReady else { return nil }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let model = try VNCoreMLModel(for: MLModel(contentsOf: Self.compiledURL, configuration: config))
            visionModel = model
            return model
        } catch {
            NSLog("WallParallax: failed to load depth model: \(error)")
            return nil
        }
    }
}
