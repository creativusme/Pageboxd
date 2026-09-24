import AVFoundation
import SwiftUI
import UIKit

// MARK: - Dispositivi e lenti

enum CameraDevices {
    struct ZoomOption: Identifiable, Hashable {
        /// Fattore di zoom del dispositivo (su quelli con ultra-grandangolo, 1 = 0,5×).
        let factor: CGFloat
        /// Etichetta come nell'app Fotocamera ("0,5", "1", "2", "3").
        let label: String

        var id: CGFloat { factor }
    }

    static var isAvailable: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }

    static var isAccessDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }

    /// La fotocamera "virtuale" che combina tutte le lenti posteriori: iOS passa da sola
    /// all'ultra-grandangolo (macro) quando il libro è molto vicino, come l'app Fotocamera.
    static func preferredBackCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back)
        for type in types {
            if let device = discovery.devices.first(where: { $0.deviceType == type }) {
                return device
            }
        }
        return AVCaptureDevice.default(for: .video)
    }

    /// Fattore che corrisponde a "1×" e le lenti disponibili.
    static func zoomPresets(for device: AVCaptureDevice) -> (wide: CGFloat, options: [ZoomOption]) {
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hasUltraWide = device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera
        let wide: CGFloat = hasUltraWide ? (switchOvers.first ?? 2) : 1

        var factors: [CGFloat] = []
        if hasUltraWide { factors.append(1) }
        factors.append(wide)
        factors.append(wide * 2)
        factors.append(contentsOf: hasUltraWide ? Array(switchOvers.dropFirst()) : switchOvers)

        let maxZoom = min(device.maxAvailableVideoZoomFactor, device.activeFormat.videoMaxZoomFactor)
        let options = Array(Set(factors.filter { $0 >= device.minAvailableVideoZoomFactor && $0 <= maxZoom }))
            .sorted()
            .map { ZoomOption(factor: $0, label: label(for: $0 / wide)) }
        return (wide, options)
    }

    static func label(for value: CGFloat) -> String {
        if value < 0.99 { return "0,5" }
        if abs(value - value.rounded()) < 0.05 { return "\(Int(value.rounded()))" }
        return String(format: "%.1f", Double(value)).replacingOccurrences(of: ".", with: ",")
    }
}

// MARK: - Modello della fotocamera

final class BookCameraModel: NSObject, ObservableObject {
    @Published private(set) var zoomOptions: [CameraDevices.ZoomOption] = []
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var wideFactor: CGFloat = 1
    @Published var flashMode: AVCaptureDevice.FlashMode = .off
    @Published private(set) var isCapturing = false
    @Published private(set) var isReady = false
    @Published private(set) var isUnavailable = false
    @Published private(set) var detectedQuad: BookQuad?

    /// Foto scattata e bordo del libro riconosciuto in quel momento.
    var onCapture: ((UIImage, BookQuad?) -> Void)?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.pageboxd.camera.session")
    private let videoQueue = DispatchQueue(label: "com.pageboxd.camera.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var isConfigured = false
    /// Accessibili solo da `videoQueue`.
    private var lastDetection = Date.distantPast
    private var pendingQuad: BookQuad?

    var displayZoom: CGFloat { wideFactor > 0 ? zoomFactor / wideFactor : zoomFactor }

    func start() {
        sessionQueue.async {
            self.configureIfNeeded()
            guard self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    // MARK: Configurazione

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        guard let device = CameraDevices.preferredBackCamera(),
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            DispatchQueue.main.async { self.isUnavailable = true }
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .photo

        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.isUnavailable = true }
            return
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .balanced

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        if let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        session.commitConfiguration()

        let presets = CameraDevices.zoomPresets(for: device)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = presets.wide
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {
            // Senza configurazione si parte dallo zoom predefinito del dispositivo.
        }

        self.device = device
        isConfigured = true
        DispatchQueue.main.async {
            self.wideFactor = presets.wide
            self.zoomFactor = presets.wide
            self.zoomOptions = presets.options
            self.isReady = true
        }
    }

    // MARK: Zoom e messa a fuoco

    func setZoom(_ factor: CGFloat, animated: Bool) {
        sessionQueue.async {
            guard let device = self.device else { return }
            let upperBound = min(device.maxAvailableVideoZoomFactor, self.wideFactor * 15)
            let clamped = min(max(factor, device.minAvailableVideoZoomFactor), upperBound)
            do {
                try device.lockForConfiguration()
                if animated {
                    device.ramp(toVideoZoomFactor: clamped, withRate: 12)
                } else {
                    device.videoZoomFactor = clamped
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.zoomFactor = clamped }
            } catch {
                // Lo zoom resta invariato.
            }
        }
    }

    /// `devicePoint` nelle coordinate del sensore (0...1).
    func focus(at devicePoint: CGPoint) {
        sessionQueue.async {
            guard let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {
                // Messa a fuoco automatica invariata.
            }
        }
    }

    // MARK: Scatto

    func capturePhoto() {
        guard !isCapturing, isReady else { return }
        isCapturing = true
        let flash = flashMode
        let quad = detectedQuad
        sessionQueue.async {
            let settings = AVCapturePhotoSettings()
            if self.photoOutput.supportedFlashModes.contains(flash) {
                settings.flashMode = flash
            }
            settings.photoQualityPrioritization = .balanced
            self.videoQueue.sync { self.pendingQuad = quad }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension BookCameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        let quad = videoQueue.sync { pendingQuad }
        DispatchQueue.main.async {
            self.isCapturing = false
            guard let image else {
                Haptics.error()
                return
            }
            Haptics.impact(.medium)
            self.onCapture?(image, quad)
        }
    }
}

extension BookCameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Riconoscimento del bordo in tempo reale, circa 4 volte al secondo.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastDetection) > 0.25,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        lastDetection = now
        let quad = BookEdgeDetector.detect(in: pixelBuffer, orientation: .right)
        DispatchQueue.main.async {
            self.detectedQuad = quad
        }
    }
}

// MARK: - Vista SwiftUI

/// Fotocamera per la foto della propria edizione, con tutte le lenti dell'iPhone.
@MainActor
struct BookCameraView: View {
    let onCapture: (UIImage, BookQuad?) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = BookCameraModel()
    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var pinchStartZoom: CGFloat? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch authorization {
            case .authorized:
                if camera.isUnavailable {
                    message(icon: "camera.metering.unknown", text: "Fotocamera non disponibile su questo dispositivo.")
                } else {
                    CameraPreview(camera: camera)
                        .ignoresSafeArea()
                        .gesture(pinchGesture)
                }
            case .notDetermined:
                ProgressView().tint(.white)
            default:
                VStack(spacing: 16) {
                    message(icon: "camera.fill", text: "Consenti l'accesso alla fotocamera nelle Impostazioni per fotografare la tua edizione.")
                    Button("Apri Impostazioni") { SystemSettings.open() }
                        .buttonStyle(.borderedProminent)
                        .tint(.pbGreen)
                }
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
        }
        .statusBarHidden()
        .task {
            if authorization == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                authorization = granted ? .authorized : .denied
            }
            guard authorization == .authorized else { return }
            camera.onCapture = { image, quad in
                onCapture(image, quad)
                dismiss()
            }
            camera.start()
        }
        .onDisappear { camera.stop() }
    }

    // MARK: Barre

    private var topBar: some View {
        HStack {
            circleButton(systemImage: "xmark", label: "Chiudi") { dismiss() }
            Spacer()
            if camera.isReady {
                circleButton(systemImage: flashIcon, label: "Flash") {
                    camera.flashMode = nextFlashMode
                    Haptics.selection()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var bottomBar: some View {
        VStack(spacing: 18) {
            Text(camera.detectedQuad == nil
                 ? "Inquadra la copertina o il dorso della tua copia"
                 : "Libro riconosciuto: scatta quando sei pronto")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .animation(.easeInOut, value: camera.detectedQuad == nil)

            if camera.zoomOptions.count > 1 {
                HStack(spacing: 8) {
                    ForEach(camera.zoomOptions) { option in
                        zoomButton(option)
                    }
                }
                .padding(6)
                .background(.black.opacity(0.4), in: Capsule())
            }

            Button {
                camera.capturePhoto()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(.white, lineWidth: 4)
                        .frame(width: 78, height: 78)
                    Circle()
                        .fill(camera.isCapturing ? Color.white.opacity(0.5) : .white)
                        .frame(width: 64, height: 64)
                }
            }
            .disabled(!camera.isReady || camera.isCapturing)
            .accessibilityLabel("Scatta foto")
        }
        .padding(.bottom, 30)
    }

    private func zoomButton(_ option: CameraDevices.ZoomOption) -> some View {
        let isSelected = abs(camera.zoomFactor - option.factor) < 0.05
        return Button {
            camera.setZoom(option.factor, animated: true)
            Haptics.selection()
        } label: {
            Text(isSelected ? "\(option.label)×" : option.label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isSelected ? Color.yellow : .white)
                .frame(width: 42, height: 42)
                .background(Circle().fill(.black.opacity(isSelected ? 0.7 : 0.35)))
        }
        .accessibilityLabel("Zoom \(option.label)×")
    }

    private func circleButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }

    private func message(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.8))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStartZoom == nil { pinchStartZoom = camera.zoomFactor }
                camera.setZoom((pinchStartZoom ?? 1) * value.magnification, animated: false)
            }
            .onEnded { _ in
                pinchStartZoom = nil
            }
    }

    private var flashIcon: String {
        switch camera.flashMode {
        case .on: return "bolt.fill"
        case .auto: return "bolt.badge.automatic.fill"
        default: return "bolt.slash.fill"
        }
    }

    private var nextFlashMode: AVCaptureDevice.FlashMode {
        switch camera.flashMode {
        case .off: return .auto
        case .auto: return .on
        default: return .off
        }
    }
}

// MARK: - Anteprima con bordo del libro

private struct CameraPreview: UIViewRepresentable {
    @ObservedObject var camera: BookCameraModel

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onTap = { devicePoint in
            camera.focus(at: devicePoint)
        }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.showQuad(camera.detectedQuad)
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    /// Sempre valido: `layerClass` garantisce il tipo del layer.
    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    var onTap: ((CGPoint) -> Void)?

    private let quadLayer = CAShapeLayer()
    private let focusLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        quadLayer.strokeColor = UIColor.pbGreen.cgColor
        quadLayer.fillColor = UIColor.pbGreen.withAlphaComponent(0.12).cgColor
        quadLayer.lineWidth = 3
        quadLayer.lineJoin = .round
        layer.addSublayer(quadLayer)

        focusLayer.strokeColor = UIColor.systemYellow.cgColor
        focusLayer.fillColor = UIColor.clear.cgColor
        focusLayer.lineWidth = 1.5
        focusLayer.opacity = 0
        layer.addSublayer(focusLayer)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) non supportato")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        quadLayer.frame = bounds
        focusLayer.frame = bounds
    }

    /// Il quadrilatero arriva nelle coordinate dell'immagine dritta; il layer le converte
    /// tenendo conto del ritaglio dell'anteprima.
    func showQuad(_ quad: BookQuad?) {
        guard let quad else {
            quadLayer.path = nil
            return
        }
        let points = quad.corners.map { point in
            // Immagine dritta (x, y) → coordinate del sensore orizzontale (y, 1 - x).
            previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: point.y, y: 1 - point.x))
        }
        let path = UIBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach { path.addLine(to: $0) }
        path.close()

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        quadLayer.path = path.cgPath
        CATransaction.commit()
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: self)
        onTap?(previewLayer.captureDevicePointConverted(fromLayerPoint: location))

        let size: CGFloat = 70
        focusLayer.path = UIBezierPath(
            roundedRect: CGRect(x: location.x - size / 2, y: location.y - size / 2, width: size, height: size),
            cornerRadius: 6
        ).cgPath
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 1, 1, 0]
        animation.keyTimes = [0, 0.1, 0.7, 1]
        animation.duration = 1.2
        focusLayer.add(animation, forKey: "focus")
    }
}
