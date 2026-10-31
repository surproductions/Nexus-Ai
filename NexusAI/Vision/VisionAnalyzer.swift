import Foundation
import Vision
import CoreGraphics
import ImageIO

/// On-device image analysis using Apple's Vision framework. Always available offline; used on its own when no
/// vision-language model is installed, and as grounding (exact OCR text) alongside one when it is.
enum VisionAnalyzer {
    struct Result: Sendable {
        var text: String
        var labels: [(String, Float)]
        var barcodes: [String]
        var faces: Int
        var size: CGSize

        var summary: String {
            var parts: [String] = ["Image \(Int(size.width))×\(Int(size.height)) px."]
            if !labels.isEmpty {
                parts.append("Likely contents (on-device classifier): " +
                             labels.map { "\($0.0.replacingOccurrences(of: "_", with: " ")) (\(Int($0.1 * 100))%)" }.joined(separator: ", ") + ".")
            }
            if faces > 0 { parts.append("Faces detected: \(faces).") }
            if !barcodes.isEmpty { parts.append("Barcodes/QR: " + barcodes.joined(separator: "; ")) }
            if !text.isEmpty { parts.append("Text found by OCR:\n\"\"\"\n\(text.truncated(to: 4000))\n\"\"\"") }
            else { parts.append("No readable text was found.") }
            return parts.joined(separator: "\n")
        }
    }

    static func analyze(_ image: CGImage) async -> Result {
        await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let ocr = VNRecognizeTextRequest()
            ocr.recognitionLevel = .accurate
            ocr.usesLanguageCorrection = true
            ocr.automaticallyDetectsLanguage = true
            let classify = VNClassifyImageRequest()
            let barcodes = VNDetectBarcodesRequest()
            let faces = VNDetectFaceRectanglesRequest()
            try? handler.perform([ocr, classify, barcodes, faces])

            let lines = (ocr.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let labels = (classify.results ?? [])
                .filter { $0.confidence > 0.25 }
                .prefix(6)
                .map { ($0.identifier, $0.confidence) }
            let codes = (barcodes.results ?? []).compactMap { $0.payloadStringValue }
            return Result(text: lines.joined(separator: "\n"), labels: Array(labels), barcodes: codes,
                          faces: faces.results?.count ?? 0,
                          size: CGSize(width: image.width, height: image.height))
        }.value
    }

    static func ocr(_ image: CGImage) -> String {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? handler.perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func loadImage(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 2048]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
