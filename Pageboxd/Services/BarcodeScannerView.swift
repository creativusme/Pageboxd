import AVFoundation
import SwiftUI
import UIKit

// MARK: - Vista SwiftUI

/// Scanner a schermo intero per codici a barre ISBN (EAN-13 978/979, ISBN-10 via inserimento manuale).
@MainActor
struct BarcodeScannerView: View {
    let onScan: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var isTorchOn = false
    @State private var isCameraUnavailable = false
    @State private var isShowingManualEntry = false
    @State private var manualISBN = ""
    @State private var manualError: String? = nil
    @State private var didScan = false
    @State private var zoomOptions: [CameraDevices.ZoomOption] = []
    @State private var currentZoom: CGFloat = 1
    @State private var zoomRequest: ZoomRequest? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            cameraContent

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomPanel
            }
        }
        .statusBarHidden()
        .task { await requestAccessIfNeeded() }
        .alert("Inserisci ISBN", isPresented: $isShowingManualEntry) {
            TextField("ISBN-10 o ISBN-13", text: $manualISBN)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Cerca") { submitManualISBN() }
            Button("Annulla", role: .cancel) { manualISBN = "" }
        } message: {
            Text("Trovi l'ISBN sul retro del libro o nella pagina del copyright.")
        }
    }

    // MARK: Contenuto fotocamera

    @ViewBuilder
    private var cameraContent: some View {
        switch authorization {
        case .authorized:
            if isCameraUnavailable {
                statusMessage(
                    systemImage: "camera.metering.unknown",
                    title: "Fotocamera non disponibile",
                    message: "Inserisci l'ISBN manualmente."
                )
            } else {
                CameraScannerRepresentable(
                    isTorchOn: $isTorchOn,
                    zoomRequest: zoomRequest,
                    onCode: handleScannedCode,
                    onFailure: { isCameraUnavailable = true },
                    onZoomOptions: { options, current in
                        zoomOptions = options
                        currentZoom = current
                    },
                    onZoomChange: { currentZoom = $0 }
                )
                .ignoresSafeArea()

                ScannerOverlay()
            }
        case .notDetermined:
            ProgressView()
                .tint(.white)
        default:
            VStack(spacing: 16) {
                statusMessage(
                    systemImage: "camera.fill",
                    title: "Accesso alla fotocamera negato",
                    message: "Consenti l'accesso alla fotocamera nelle Impostazioni per scansionare i codici a barre."
                )
                Button("Apri Impostazioni") { SystemSettings.open() }
                    .buttonStyle(.borderedProminent)
                    .tint(.pbGreen)
            }
        }
    }

    private func statusMessage(systemImage: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.8))
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    // MARK: Barre

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Chiudi")

            Spacer()

            if authorization == .authorized && !isCameraUnavailable {
                Button {
                    isTorchOn.toggle()
                    Haptics.impact(.light)
                } label: {
                    Image(systemName: isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(isTorchOn ? "Spegni torcia" : "Accendi torcia")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var bottomPanel: some View {
        VStack(spacing: 14) {
            if zoomOptions.count > 1 && authorization == .authorized && !isCameraUnavailable {
                HStack(spacing: 8) {
                    ForEach(zoomOptions) { option in
                        let isSelected = abs(currentZoom - option.factor) < 0.05
                        Button {
                            zoomRequest = ZoomRequest(factor: option.factor)
                            Haptics.selection()
                        } label: {
                            Text(isSelected ? "\(option.label)×" : option.label)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(isSelected ? Color.yellow : .white)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(.black.opacity(isSelected ? 0.7 : 0.35)))
                        }
                        .accessibilityLabel("Zoom \(option.label)×")
                    }
                }
                .padding(6)
                .background(.black.opacity(0.4), in: Capsule())
            }

            Text("Inquadra il codice a barre sul retro del libro")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            if let manualError {
                Text(manualError)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.pbOrange)
                    .transition(.opacity)
            }

            Button {
                manualError = nil
                isShowingManualEntry = true
            } label: {
                Label("Inserisci ISBN manualmente", systemImage: "keyboard")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
        .animation(.easeInOut, value: manualError)
    }

    // MARK: Azioni

    private func requestAccessIfNeeded() async {
        guard authorization == .notDetermined else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        authorization = granted ? .authorized : .denied
    }

    private func handleScannedCode(_ isbn: String) {
        guard !didScan else { return }
        didScan = true
        isTorchOn = false
        Haptics.impact(.heavy)
        Haptics.success()
        onScan(isbn)
        dismiss()
    }

    private func submitManualISBN() {
        guard let isbn = ISBN.normalize(manualISBN) else {
            manualError = "ISBN non valido. Controlla le cifre e riprova."
            Haptics.error()
            return
        }
        manualISBN = ""
        handleScannedCode(isbn)
    }
}

// MARK: - Overlay mirino

private struct ScannerOverlay: View {
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width - 64, 340)
            let height = width * 0.6
            let frame = CGRect(
                x: (geometry.size.width - width) / 2,
                y: (geometry.size.height - height) / 2 - 40,
                width: width,
                height: height
            )

            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    path.addRoundedRect(in: frame, cornerSize: CGSize(width: 20, height: 20), style: .continuous)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.pbGreen, lineWidth: 3)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, Color.pbGreen.opacity(0.9), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: frame.width - 32, height: 2)
                    .position(
                        x: frame.midX,
                        y: isAnimating ? frame.maxY - 18 : frame.minY + 18
                    )
                    .shadow(color: Color.pbGreen.opacity(0.8), radius: 6)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

// MARK: - Bridge UIKit

/// Richiesta di zoom da un pulsante: l'identificativo permette di ripetere la stessa lente dopo un pizzico.
struct ZoomRequest: Equatable {
    let id = UUID()
    let factor: CGFloat
}

private struct CameraScannerRepresentable: UIViewControllerRepresentable {
    @Binding var isTorchOn: Bool
    let zoomRequest: ZoomRequest?
    let onCode: (String) -> Void
    let onFailure: () -> Void
    let onZoomOptions: ([CameraDevices.ZoomOption], CGFloat) -> Void
    let onZoomChange: (CGFloat) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onCode = onCode
        controller.onFailure = onFailure
        controller.onZoomOptions = onZoomOptions
        controller.onZoomChange = onZoomChange
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {
        controller.onCode = onCode
        controller.onFailure = onFailure
        controller.onZoomOptions = onZoomOptions
        controller.onZoomChange = onZoomChange
        controller.setTorch(isOn: isTorchOn)
        if let zoomRequest {
            controller.apply(zoomRequest)
        }
    }

    static func dismantleUIViewController(_ controller: ScannerViewController, coordinator: ()) {
        controller.stopSession()
    }
}

// MARK: - Controller AVFoundation

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onFailure: (() -> Void)?
    var onZoomOptions: (([CameraDevices.ZoomOption], CGFloat) -> Void)?
    var onZoomChange: ((CGFloat) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.pageboxd.scanner.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureDevice: AVCaptureDevice?
    private var hasReportedCode = false
    private var isConfigured = false
    private var wideZoomFactor: CGFloat = 1
    private var lastZoomRequestID: UUID?
    private var pinchStartZoom: CGFloat = 1

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setTorch(isOn: false)
        stopSession()
    }

    // MARK: Configurazione

    private func configureSession() {
        // Fotocamera "virtuale" con tutte le lenti: da vicino iOS passa da solo alla macro,
        // quindi non serve più ingrandire l'immagine per mettere a fuoco il codice.
        guard let device = CameraDevices.preferredBackCamera(),
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            reportFailure()
            return
        }

        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            reportFailure()
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            reportFailure()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)

        let wantedTypes: [AVMetadataObject.ObjectType] = [.ean13, .code128, .code39]
        output.metadataObjectTypes = wantedTypes.filter { output.availableMetadataObjectTypes.contains($0) }
        session.commitConfiguration()

        captureDevice = device
        configureLenses(for: device)

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
        isConfigured = true
    }

    /// Parte da "1×" come l'app Fotocamera e comunica le lenti disponibili alla vista SwiftUI.
    private func configureLenses(for device: AVCaptureDevice) {
        let presets = CameraDevices.zoomPresets(for: device)
        wideZoomFactor = presets.wide
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = presets.wide
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            }
            device.unlockForConfiguration()
        } catch {
            // Senza configurazione la scansione funziona comunque con le impostazioni predefinite.
        }
        let options = presets.options
        let current = presets.wide
        DispatchQueue.main.async { [weak self] in
            self?.onZoomOptions?(options, current)
        }
    }

    // MARK: Zoom

    func apply(_ request: ZoomRequest) {
        guard request.id != lastZoomRequestID else { return }
        lastZoomRequestID = request.id
        setZoom(request.factor, animated: true)
    }

    private func setZoom(_ factor: CGFloat, animated: Bool) {
        guard let device = captureDevice else { return }
        let upperBound = min(device.maxAvailableVideoZoomFactor, wideZoomFactor * 10)
        let clamped = min(max(factor, device.minAvailableVideoZoomFactor), upperBound)
        do {
            try device.lockForConfiguration()
            if animated {
                device.ramp(toVideoZoomFactor: clamped, withRate: 12)
            } else {
                device.videoZoomFactor = clamped
            }
            device.unlockForConfiguration()
            onZoomChange?(clamped)
        } catch {
            // Lo zoom resta invariato.
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard let device = captureDevice else { return }
        switch recognizer.state {
        case .began:
            pinchStartZoom = device.videoZoomFactor
        case .changed:
            setZoom(pinchStartZoom * recognizer.scale, animated: false)
        default:
            break
        }
    }

    private func reportFailure() {
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?()
        }
    }

    // MARK: Sessione

    func startSession() {
        guard isConfigured else { return }
        hasReportedCode = false
        let session = self.session
        sessionQueue.async {
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func stopSession() {
        let session = self.session
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func setTorch(isOn: Bool) {
        guard let device = captureDevice, device.hasTorch, device.isTorchAvailable else { return }
        let desiredMode: AVCaptureDevice.TorchMode = isOn ? .on : .off
        guard device.torchMode != desiredMode else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = desiredMode
            device.unlockForConfiguration()
        } catch {
            // La torcia non è essenziale: in caso di errore resta nello stato precedente.
        }
    }

    // MARK: AVCaptureMetadataOutputObjectsDelegate

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let values = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        MainActor.assumeIsolated {
            self.handle(values)
        }
    }

    private func handle(_ values: [String]) {
        guard !hasReportedCode else { return }
        for value in values {
            guard let isbn = ISBN.normalize(value) else { continue }
            hasReportedCode = true
            stopSession()
            onCode?(isbn)
            return
        }
    }
}
