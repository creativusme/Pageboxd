import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import UIKit
import Vision

/// Quadrilatero del libro in coordinate normalizzate (0...1), origine in alto a sinistra, immagine dritta.
struct BookQuad: Equatable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    static let full = BookQuad(
        topLeft: CGPoint(x: 0, y: 0),
        topRight: CGPoint(x: 1, y: 0),
        bottomRight: CGPoint(x: 1, y: 1),
        bottomLeft: CGPoint(x: 0, y: 1)
    )

    /// Vision usa l'origine in basso a sinistra.
    init(observation: VNRectangleObservation) {
        topLeft = CGPoint(x: observation.topLeft.x, y: 1 - observation.topLeft.y)
        topRight = CGPoint(x: observation.topRight.x, y: 1 - observation.topRight.y)
        bottomRight = CGPoint(x: observation.bottomRight.x, y: 1 - observation.bottomRight.y)
        bottomLeft = CGPoint(x: observation.bottomLeft.x, y: 1 - observation.bottomLeft.y)
    }

    init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    subscript(index: Int) -> CGPoint {
        get { corners[index] }
        set {
            switch index {
            case 0: topLeft = newValue
            case 1: topRight = newValue
            case 2: bottomRight = newValue
            default: bottomLeft = newValue
            }
        }
    }

    /// Area normalizzata (formula di Gauss).
    var area: CGFloat {
        let points = corners
        var sum: CGFloat = 0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            sum += current.x * next.y - next.x * current.y
        }
        return abs(sum) / 2
    }

    var isFullFrame: Bool {
        corners.enumerated().allSatisfy { index, point in
            let reference = BookQuad.full.corners[index]
            return abs(point.x - reference.x) < 0.01 && abs(point.y - reference.y) < 0.01
        }
    }

    /// Allarga leggermente il riquadro per non tagliare il bordo del libro.
    func expanded(by amount: CGFloat) -> BookQuad {
        let centerX = corners.map(\.x).reduce(0, +) / 4
        let centerY = corners.map(\.y).reduce(0, +) / 4
        func push(_ point: CGPoint) -> CGPoint {
            let dx = point.x - centerX
            let dy = point.y - centerY
            return CGPoint(
                x: min(max(point.x + dx * amount, 0), 1),
                y: min(max(point.y + dy * amount, 0), 1)
            )
        }
        return BookQuad(topLeft: push(topLeft), topRight: push(topRight), bottomRight: push(bottomRight), bottomLeft: push(bottomLeft))
    }
}

/// Riconoscimento del bordo del libro, interamente sul dispositivo (Vision).
enum BookEdgeDetector {
    static func detect(in cgImage: CGImage) -> BookQuad? {
        detect(using: VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:]))
    }

    /// Fotogrammi della fotocamera: `.right` per un iPhone tenuto in verticale.
    static func detect(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> BookQuad? {
        detect(using: VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:]))
    }

    private static func detect(using handler: VNImageRequestHandler) -> BookQuad? {
        // Segmentazione del documento: rete neurale, affidabile anche su copertine illustrate.
        let segmentation = VNDetectDocumentSegmentationRequest()
        // Rettangoli classici: preciso sui bordi netti.
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 6
        rectangles.minimumConfidence = 0.5
        rectangles.minimumSize = 0.15
        rectangles.minimumAspectRatio = 0.25
        rectangles.maximumAspectRatio = 1.0
        rectangles.quadratureTolerance = 30

        do {
            try handler.perform([segmentation, rectangles])
        } catch {
            return nil
        }

        var candidates: [(quad: BookQuad, score: Double)] = []
        if let document = segmentation.results?.first, document.confidence >= 0.4 {
            candidates.append((BookQuad(observation: document), Double(document.confidence) + 0.25))
        }
        for observation in rectangles.results ?? [] {
            candidates.append((BookQuad(observation: observation), Double(observation.confidence)))
        }

        // Scarta riquadri minuscoli o coincidenti con l'intera foto; a parità preferisce i più grandi.
        return candidates
            .filter { (0.06...0.97).contains($0.quad.area) }
            .max { lhs, rhs in
                lhs.score * Double(lhs.quad.area).squareRoot() < rhs.score * Double(rhs.quad.area).squareRoot()
            }?
            .quad
    }

    /// Raddrizza la prospettiva: il quadrilatero diventa un rettangolo.
    static func perspectiveCorrected(_ image: UIImage, quad: BookQuad) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let input = CIImage(cgImage: cgImage)

        // Core Image ha l'origine in basso a sinistra.
        func point(_ normalized: CGPoint) -> CGPoint {
            CGPoint(x: normalized.x * width, y: (1 - normalized.y) * height)
        }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = input
        filter.topLeft = point(quad.topLeft)
        filter.topRight = point(quad.topRight)
        filter.bottomRight = point(quad.bottomRight)
        filter.bottomLeft = point(quad.bottomLeft)

        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let result = context.createCGImage(output, from: output.extent.integral) else { return nil }
        return UIImage(cgImage: result, scale: 1, orientation: .up)
    }
}
