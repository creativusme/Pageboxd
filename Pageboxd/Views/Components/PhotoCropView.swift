import SwiftUI
import UIKit

/// Ritaglio della foto dell'edizione: bordo del libro riconosciuto automaticamente (Vision, offline),
/// quattro angoli trascinabili con lente d'ingrandimento e correzione della prospettiva.
@MainActor
struct PhotoCropView: View {
    let onCropped: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage
    @State private var quad: BookQuad = .full
    @State private var dragStartQuad: BookQuad? = nil
    @State private var activeCorner: Int? = nil
    @State private var isDetecting = false
    @State private var isRendering = false
    @State private var statusMessage: String? = nil

    /// Bordo riconosciuto dalla fotocamera al momento dello scatto (usato se l'analisi della foto non trova nulla).
    private let suggestedQuad: BookQuad?
    private let handleHitSize: CGFloat = 44
    private let loupeDiameter: CGFloat = 116
    private let loupeZoom: CGFloat = 2.5

    init(image: UIImage, suggestedQuad: BookQuad? = nil, onCropped: @escaping (UIImage) -> Void) {
        _image = State(initialValue: image)
        self.suggestedQuad = suggestedQuad
        self.onCropped = onCropped
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            topBar
            GeometryReader { geometry in
                cropCanvas(in: geometry.size)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            bottomControls
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .overlay {
            if isRendering {
                ProgressView("Raddrizzo la foto…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .task { await detectBookEdges(isInitial: true) }
    }

    private var topBar: some View {
        HStack {
            Button("Annulla") { dismiss() }
            Spacer()
            Text("Ritaglia")
                .font(.headline)
            Spacer()
            Button("Fine") {
                Task { await finish() }
            }
            .fontWeight(.semibold)
            .tint(.pbGreen)
            .disabled(isRendering)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var bottomControls: some View {
        VStack(spacing: 16) {
            Text(statusMessage ?? "Trascina gli angoli sui bordi del libro: la prospettiva viene raddrizzata")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(minHeight: 34)

            HStack(spacing: 12) {
                controlButton("Auto", systemImage: "wand.and.stars") {
                    Task { await detectBookEdges(isInitial: false) }
                }
                .disabled(isDetecting)
                controlButton("Ruota", systemImage: "rotate.left") {
                    rotate()
                }
                controlButton("Intera", systemImage: "arrow.up.left.and.arrow.down.right") {
                    withAnimation(.snappy(duration: 0.2)) { quad = .full }
                    statusMessage = "Foto intera, senza ritaglio"
                    Haptics.impact(.light)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    private func controlButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .foregroundStyle(.white)
    }

    // MARK: Canvas

    private func cropCanvas(in size: CGSize) -> some View {
        let imageFrame = fittedImageFrame(in: size)
        let viewCorners = quad.corners.map { viewPoint($0, in: imageFrame) }

        return ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: imageFrame.width, height: imageFrame.height)
                .position(x: imageFrame.midX, y: imageFrame.midY)

            // Oscura tutto ciò che resta fuori dal libro.
            Path { path in
                path.addRect(imageFrame)
                path.addLines(viewCorners)
                path.closeSubpath()
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            QuadShape(points: viewCorners)
                .stroke(Color.pbGreen, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                .allowsHitTesting(false)

            // Trascinando dentro il riquadro lo si sposta tutto.
            QuadShape(points: viewCorners)
                .fill(Color.white.opacity(0.001))
                .gesture(moveGesture(imageFrame: imageFrame))

            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(Color.pbGreen)
                    .frame(width: activeCorner == index ? 26 : 20, height: activeCorner == index ? 26 : 20)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .frame(width: handleHitSize, height: handleHitSize)
                    .contentShape(Rectangle())
                    .position(viewCorners[index])
                    .gesture(cornerGesture(index, imageFrame: imageFrame))
            }

            if let activeCorner {
                loupe(for: quad[activeCorner], imageFrame: imageFrame, canvasSize: size)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// Lente d'ingrandimento sull'angolo che si sta spostando, sul lato opposto al dito.
    private func loupe(for point: CGPoint, imageFrame: CGRect, canvasSize: CGSize) -> some View {
        let scaledWidth = imageFrame.width * loupeZoom
        let scaledHeight = imageFrame.height * loupeZoom
        let fingerX = viewPoint(point, in: imageFrame).x
        let centerX = fingerX < canvasSize.width / 2
            ? canvasSize.width - loupeDiameter / 2 - 4
            : loupeDiameter / 2 + 4

        return Image(uiImage: image)
            .resizable()
            .frame(width: scaledWidth, height: scaledHeight)
            .offset(x: loupeDiameter / 2 - point.x * scaledWidth, y: loupeDiameter / 2 - point.y * scaledHeight)
            .frame(width: loupeDiameter, height: loupeDiameter, alignment: .topLeading)
            .clipShape(Circle())
            .overlay {
                ZStack {
                    Rectangle().fill(Color.pbGreen).frame(width: 1.5, height: 22)
                    Rectangle().fill(Color.pbGreen).frame(width: 22, height: 1.5)
                }
            }
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.5), radius: 8)
            .position(x: centerX, y: loupeDiameter / 2 + 4)
            .allowsHitTesting(false)
    }

    private func fittedImageFrame(in size: CGSize) -> CGRect {
        guard image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func viewPoint(_ normalized: CGPoint, in imageFrame: CGRect) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + normalized.x * imageFrame.width,
            y: imageFrame.minY + normalized.y * imageFrame.height
        )
    }

    // MARK: Gesti

    private func cornerGesture(_ index: Int, imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartQuad == nil {
                    dragStartQuad = quad
                    activeCorner = index
                }
                guard let start = dragStartQuad, imageFrame.width > 0, imageFrame.height > 0 else { return }
                let original = start[index]
                let moved = CGPoint(
                    x: min(max(original.x + value.translation.width / imageFrame.width, 0), 1),
                    y: min(max(original.y + value.translation.height / imageFrame.height, 0), 1)
                )
                var updated = start
                updated[index] = moved
                quad = updated
            }
            .onEnded { _ in
                dragStartQuad = nil
                activeCorner = nil
                statusMessage = nil
                Haptics.impact(.light, intensity: 0.6)
            }
    }

    private func moveGesture(imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartQuad == nil { dragStartQuad = quad }
                guard let start = dragStartQuad, imageFrame.width > 0, imageFrame.height > 0 else { return }
                let xs = start.corners.map(\.x)
                let ys = start.corners.map(\.y)
                let dx = min(max(value.translation.width / imageFrame.width, -(xs.min() ?? 0)), 1 - (xs.max() ?? 1))
                let dy = min(max(value.translation.height / imageFrame.height, -(ys.min() ?? 0)), 1 - (ys.max() ?? 1))
                var updated = start
                for index in 0..<4 {
                    let point = start[index]
                    updated[index] = CGPoint(x: point.x + dx, y: point.y + dy)
                }
                quad = updated
            }
            .onEnded { _ in
                dragStartQuad = nil
            }
    }

    // MARK: Azioni

    private func detectBookEdges(isInitial: Bool) async {
        isDetecting = true
        defer { isDetecting = false }

        let detected = await Self.detectQuad(in: image)
        guard !Task.isCancelled else { return }

        if let detected {
            withAnimation(.snappy(duration: 0.25)) { quad = detected.expanded(by: 0.015) }
            statusMessage = "Bordi del libro riconosciuti: correggi gli angoli se serve"
            Haptics.impact(.light)
        } else if isInitial, let suggestedQuad {
            withAnimation(.snappy(duration: 0.25)) { quad = suggestedQuad.expanded(by: 0.015) }
            statusMessage = "Bordi presi dalla fotocamera: correggi gli angoli se serve"
        } else {
            statusMessage = "Bordi non riconosciuti: trascina gli angoli sul libro"
            if isInitial { quad = .full }
        }
    }

    private func rotate() {
        let size = image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rotatedSize = CGSize(width: size.height, height: size.width)
        let source = image
        let rotated = UIGraphicsImageRenderer(size: rotatedSize, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: 0, y: rotatedSize.height)
            cg.rotate(by: -.pi / 2)
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        image = rotated
        quad = .full
        Haptics.impact(.medium)
        Task { await detectBookEdges(isInitial: false) }
    }

    private func finish() async {
        guard !quad.isFullFrame else {
            onCropped(image)
            Haptics.success()
            dismiss()
            return
        }
        isRendering = true
        let result = await Self.render(image, quad: quad)
        isRendering = false
        onCropped(result ?? image)
        Haptics.success()
        dismiss()
    }

    // MARK: Elaborazione fuori dal main thread

    nonisolated private static func detectQuad(in image: UIImage) async -> BookQuad? {
        guard let cgImage = image.cgImage else { return nil }
        return BookEdgeDetector.detect(in: cgImage)
    }

    nonisolated private static func render(_ image: UIImage, quad: BookQuad) async -> UIImage? {
        BookEdgeDetector.perspectiveCorrected(image, quad: quad)
    }
}

// MARK: - Forma del riquadro

private struct QuadShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count == 4 else { return path }
        path.addLines(points)
        path.closeSubpath()
        return path
    }
}
