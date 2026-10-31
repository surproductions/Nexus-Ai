import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import AVFoundation
import UIKit

/// Deterministic, on-device media operations. These are classic (non-generative) image/video processing steps and
/// are labelled as such in the UI.
enum LocalMediaOps {
    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func render(_ image: CIImage) -> CGImage? { ciContext.createCGImage(image, from: image.extent) }

    static func squareResize(_ image: CGImage, side: Int) -> CGImage? {
        guard let cropped = centerCrop(image, aspect: 1) else { return nil }
        return resize(cropped, width: side, height: side)
    }

    static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    static func centerCrop(_ image: CGImage, aspect: Double) -> CGImage? {
        let w = Double(image.width), h = Double(image.height)
        var cw = w, ch = h
        if w / h > aspect { cw = h * aspect } else { ch = w / aspect }
        let rect = CGRect(x: (w - cw) / 2, y: (h - ch) / 2, width: cw, height: ch).integral
        return image.cropping(to: rect)
    }

    /// Scales to cover the target size then center-crops (used for provider reference images that must match exactly).
    static func aspectFill(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let cropped = centerCrop(image, aspect: Double(width) / Double(height)) else { return nil }
        return resize(cropped, width: width, height: height)
    }

    // MARK: Background

    /// Subject lifting with Vision (iOS 17+). Returns the foreground on a transparent background.
    static func removeBackground(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first else {
            throw CreativeError.unsupported("No distinct foreground subject was found in this image.")
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        guard let cg = render(CIImage(cvPixelBuffer: buffer)) else { throw CreativeError.noOutput }
        return cg
    }

    static func hasForegroundSubject(_ image: CGImage) -> Bool {
        let request = VNGenerateForegroundInstanceMaskRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return !(request.results?.first?.allInstances.isEmpty ?? true)
    }

    /// Places the lifted subject over a new background (scaled to fill).
    static func composite(subject: CGImage, over background: CGImage) -> CGImage? {
        let size = CGSize(width: subject.width, height: subject.height)
        guard let bg = aspectFill(background, width: subject.width, height: subject.height) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            ctx.cgContext.draw(bg, in: CGRect(origin: .zero, size: size))
            ctx.cgContext.draw(subject, in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    // MARK: Enhancement (classic, non-generative)

    static func autoEnhance(_ image: CGImage) -> CGImage? {
        var ci = CIImage(cgImage: image)
        for filter in ci.autoAdjustmentFilters(options: [.redEye: false]) {
            filter.setValue(ci, forKey: kCIInputImageKey)
            if let out = filter.outputImage { ci = out }
        }
        return render(ci)
    }

    static func warmer(_ image: CGImage, amount: Double = 1) -> CGImage? {
        let f = CIFilter.temperatureAndTint()
        f.inputImage = CIImage(cgImage: image)
        f.neutral = CIVector(x: 6500, y: 0)
        f.targetNeutral = CIVector(x: 6500 - 1500 * amount, y: 0)
        return f.outputImage.flatMap(render)
    }

    /// 2× Lanczos resampling plus mild sharpening. Not AI super-resolution; labelled accordingly.
    static func upscale(_ image: CGImage, factor: Double = 2) -> CGImage? {
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = CIImage(cgImage: image)
        f.scale = Float(factor)
        f.aspectRatio = 1
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = f.outputImage
        sharpen.sharpness = 0.4
        return sharpen.outputImage.flatMap(render)
    }

    // MARK: Video

    static func videoSize(_ asset: AVAsset) async -> CGSize? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) else { return nil }
        let r = CGRect(origin: .zero, size: natural).applying(t)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    static func lastFrame(of url: URL) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let t = CMTimeSubtract(duration, CMTime(value: 1, timescale: 30))
        return try gen.copyCGImage(at: t, actualTime: nil)
    }

    private static func export(_ composition: AVAsset, videoComposition: AVVideoComposition?, preset: String = AVAssetExportPresetHighestQuality) async throws -> URL {
        guard let export = AVAssetExportSession(asset: composition, presetName: preset) else { throw CreativeError.unsupported("Export not supported for this video.") }
        let out = MediaFiles.newURL(ext: "mp4")
        export.outputURL = out
        export.outputFileType = .mp4
        export.videoComposition = videoComposition
        let status: AVAssetExportSession.Status = await withCheckedContinuation { c in
            export.exportAsynchronously { c.resume(returning: export.status) }
        }
        guard status == .completed else { throw CreativeError.provider("Video export failed: \(export.error?.localizedDescription ?? "unknown error")") }
        return out
    }

    /// Center-crops a video to 9:16 for vertical social formats (local, non-generative).
    static func verticalCrop(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CreativeError.unsupported("No video track.") }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let display = CGRect(origin: .zero, size: natural).applying(transform)
        let w = abs(display.width), h = abs(display.height)
        let targetW = min(w, h * 9 / 16)
        let renderSize = CGSize(width: (targetW / 2).rounded() * 2, height: (h / 2).rounded() * 2)
        let duration = try await asset.load(.duration)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let offset = (w - targetW) / 2
        layer.setTransform(transform.concatenating(CGAffineTransform(translationX: -offset, y: 0)), at: .zero)
        instruction.layerInstructions = [layer]
        let vc = AVMutableVideoComposition()
        vc.renderSize = renderSize
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        vc.instructions = [instruction]
        return try await export(asset, videoComposition: vc)
    }

    /// Joins clips end to end (used to append an extension clip to an original video).
    static func concatenate(_ urls: [URL]) async throws -> URL {
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CreativeError.provider("Could not create composition")
        }
        let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        var firstTransform: CGAffineTransform?
        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            if let v = try await asset.loadTracks(withMediaType: .video).first {
                try vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: v, at: cursor)
                if firstTransform == nil { firstTransform = try await v.load(.preferredTransform) }
            }
            if let a = try await asset.loadTracks(withMediaType: .audio).first {
                try aTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: a, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        if let firstTransform { vTrack.preferredTransform = firstTransform }
        return try await export(comp, videoComposition: nil)
    }
}
