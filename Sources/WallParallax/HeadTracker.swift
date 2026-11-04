import AVFoundation
import Combine
import Vision

/// Head position relative to the calibrated neutral position.
/// x: + = viewer moved right, y: + = viewer moved up, z: + = viewer leaned in. Roughly -1...1.
struct HeadPose: Equatable {
    var x = 0.0
    var y = 0.0
    var z = 0.0
    static let zero = HeadPose()
}

/// Captures the camera and detects the largest face with Vision.
final class HeadTracker: NSObject, ObservableObject {
    static let shared = HeadTracker()

    enum Status: Equatable {
        case idle, starting, running, denied, noCamera
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var pose = HeadPose()
    @Published private(set) var faceVisible = false

    var smoothing = 0.5 { didSet { updateFilterParams() } }
    var invertHorizontal = false
    var autoRecenter = true

    // Camera (touched on videoQueue only)
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "WallParallax.camera", qos: .userInteractive)
    private var isConfigured = false

    // Tracking state (main thread)
    private typealias Sample = (x: Double, y: Double, size: Double)
    private var neutral: Sample?
    private var lastRaw: Sample?
    private var filters = [OneEuroFilter](repeating: OneEuroFilter(), count: 3)
    private var lastSeen: Double = 0
    private var lastSampleTime: Double = 0
    private var wantsRunning = false

    /// How far (in normalized image units) the face center moves for a "full" (1.0) offset.
    private let travel = 0.17
    /// Relative face-size change that counts as a full lean.
    private let leanTravel = 0.35

    override init() {
        super.init()
        updateFilterParams()
    }

    // MARK: Control

    func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            status = .starting
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    guard self.wantsRunning else { return }
                    if granted { self.startSession() } else { self.status = .denied }
                }
            }
        default:
            status = .denied
        }
    }

    func stop() {
        wantsRunning = false
        videoQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
        status = .idle
        faceVisible = false
        filters.indices.forEach { filters[$0].reset() }
    }

    /// Make the current head position the neutral (centered) one.
    func recenter() {
        if let lastRaw { neutral = lastRaw }
        filters.indices.forEach { filters[$0].reset() }
    }

    private func startSession() {
        status = .starting
        videoQueue.async {
            do {
                if !self.isConfigured { try self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async {
                    if self.wantsRunning { self.status = .running }
                }
            } catch TrackerError.noCamera {
                DispatchQueue.main.async { self.status = .noCamera }
            } catch {
                DispatchQueue.main.async { self.status = .failed(error.localizedDescription) }
            }
        }
    }

    private enum TrackerError: Error { case noCamera, cannotAddIO }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
        else { throw TrackerError.noCamera }

        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else if session.canSetSessionPreset(.low) {
            session.sessionPreset = .low
        }
        guard session.canAddInput(input) else { throw TrackerError.cannotAddIO }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { throw TrackerError.cannotAddIO }
        session.addOutput(output)
        isConfigured = true
    }

    private func updateFilterParams() {
        // smoothing 0 → responsive, 1 → very smooth
        let minCutoff = 3.0 * pow(0.08, smoothing)   // 3.0 ... 0.24 Hz
        for i in filters.indices {
            filters[i].minCutoff = minCutoff
            filters[i].beta = 0.6
        }
    }

    // MARK: Processing (main thread)

    fileprivate func ingest(face: CGRect?, time t: Double) {
        guard wantsRunning else { return }
        let dt = lastSampleTime > 0 ? min(0.5, max(0, t - lastSampleTime)) : 0
        lastSampleTime = t

        guard let face else {
            if faceVisible, t - lastSeen > 0.6 {
                faceVisible = false
                filters.indices.forEach { filters[$0].reset() }
            }
            return
        }

        lastSeen = t
        // Vision: normalized, origin bottom-left, raw (unmirrored) camera image.
        let raw: Sample = (face.midX, face.midY, face.width)
        lastRaw = raw
        if neutral == nil { neutral = (0.5, raw.y, raw.size) }
        guard var n = neutral else { return }

        if autoRecenter, dt > 0 {
            // Very slowly drift neutral toward wherever the user habitually sits.
            let k = dt / 45
            n.x += (raw.x - n.x) * k
            n.y += (raw.y - n.y) * k
            n.size += (raw.size - n.size) * k
            neutral = n
        }

        // The camera sees the user un-mirrored: when the user moves to their right,
        // their face moves to the left of the image.
        var x = -(raw.x - n.x) / travel
        if invertHorizontal { x = -x }
        let y = (raw.y - n.y) / travel
        let z = (raw.size / max(n.size, 0.01) - 1) / leanTravel

        let clamp: (Double) -> Double = { min(1.5, max(-1.5, $0)) }
        pose = HeadPose(
            x: filters[0].filter(clamp(x), at: t),
            y: filters[1].filter(clamp(y), at: t),
            z: filters[2].filter(clamp(z), at: t)
        )
        faceVisible = true
    }
}

extension HeadTracker: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])

        let face = request.results?
            .max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }?
            .boundingBox

        DispatchQueue.main.async { self.ingest(face: face, time: time) }
    }
}
