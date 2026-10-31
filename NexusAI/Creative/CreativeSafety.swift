import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

/// On-device pre-screening of generation/edit requests. Providers apply their own (stricter) policies as well;
/// the local Stable Diffusion pipeline additionally runs Apple's safety checker on outputs.
enum CreativeSafety {
    struct Verdict { var allowed: Bool; var reason: String }

    private static let minors = ["child", "children", "kid", "kids", "minor", "underage", "teen", "teenager", "boy", "girl",
                                 "toddler", "baby", "schoolgirl", "schoolboy", "preteen", "young-looking", "loli", "shota"]
    private static let sexual = ["nude", "naked", "nsfw", "sex", "sexual", "porn", "explicit", "topless", "lingerie", "erotic",
                                 "undress", "undressed", "genitals", "fetish", "onlyfans", "stripping"]
    private static let ncii = ["undress", "remove her clothes", "remove his clothes", "remove their clothes", "make her naked",
                               "make him naked", "nudify", "see through clothes", "x-ray clothes"]
    private static let deception = ["fake id", "passport photo of", "driver's license", "forged", "counterfeit money",
                                    "fake news photo", "fake evidence", "make it look like a real photo of the president",
                                    "deepfake", "fake receipt", "fake screenshot of a bank"]

    static func check(prompt: String, editingUploadedPhoto: Bool, uploadedHasPeople: Bool) -> Verdict {
        let t = prompt.lowercased()
        func word(_ w: String) -> Bool {
            t.range(of: "\\b" + NSRegularExpression.escapedPattern(for: w) + "\\b", options: .regularExpression) != nil
        }
        let hasSexual = sexual.contains(where: word)
        if hasSexual && minors.contains(where: word) {
            return Verdict(allowed: false, reason: "Sexual content involving minors is never generated.")
        }
        if ncii.contains(where: { t.contains($0) }) || (editingUploadedPhoto && uploadedHasPeople && hasSexual) {
            return Verdict(allowed: false, reason: "Sexualized edits of real people's photos (non-consensual intimate imagery) are not allowed.")
        }
        if hasSexual {
            return Verdict(allowed: false, reason: "Sexual content generation is not supported in NEXUS.")
        }
        if let d = deception.first(where: { t.contains($0) }) {
            return Verdict(allowed: false, reason: "Requests intended to create deceptive documents or fake evidence (“\(d)”) are not allowed.")
        }
        return Verdict(allowed: true, reason: "")
    }
}

/// Writes AI-generation disclosures into saved media (IPTC Digital Source Type + description).
enum Provenance {
    static let digitalSourceType = "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"
    static let compositeSourceType = "http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia"

    /// Encodes a CGImage as PNG/JPEG with provenance metadata.
    static func write(_ image: CGImage, to url: URL, model: String, provider: String, prompt: String, edited: Bool) throws {
        let type: UTType = url.pathExtension.lowercased() == "png" ? .png : .jpeg
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CreativeError.provider("Could not write image")
        }
        let description = "AI-generated with \(model) via \(provider) in NEXUS AI. Prompt: \(prompt.truncated(to: 400))"
        let iptc: [CFString: Any] = [
            kCGImagePropertyIPTCExtDigitalSourceType: edited ? compositeSourceType : digitalSourceType,
            kCGImagePropertyIPTCCaptionAbstract: description,
            kCGImagePropertyIPTCOriginatingProgram: "NEXUS AI",
        ]
        let tiff: [CFString: Any] = [kCGImagePropertyTIFFSoftware: "NEXUS AI · \(model)", kCGImagePropertyTIFFImageDescription: description]
        var props: [CFString: Any] = [kCGImagePropertyIPTCDictionary: iptc, kCGImagePropertyTIFFDictionary: tiff]
        if type == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CreativeError.provider("Could not encode image") }
    }

    /// Re-saves encoded image bytes from a provider while adding provenance (keeps provider-embedded metadata such as C2PA
    /// when the bytes are stored as-is; used only when the provider did not include its own credentials).
    static func save(data: Data, ext: String, model: String, provider: String, prompt: String, edited: Bool) throws -> URL {
        let url = MediaFiles.newURL(ext: ext)
        if let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
           !(hasContentCredentials(data)) {
            try write(img, to: url, model: model, provider: provider, prompt: prompt, edited: edited)
        } else {
            try data.write(to: url)
        }
        return url
    }

    /// Detects an embedded C2PA manifest (JUMBF "c2pa" label) so we never strip a provider's content credentials.
    static func hasContentCredentials(_ data: Data) -> Bool {
        data.range(of: Data("c2pa".utf8), options: [], in: 0..<min(data.count, 400_000)) != nil
    }

    /// Adds an AI-generated description to a video's metadata via passthrough export.
    static func tagVideo(at url: URL, model: String, provider: String, prompt: String) async -> URL {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return url }
        let out = MediaFiles.newURL(ext: "mp4")
        let desc = AVMutableMetadataItem()
        desc.identifier = .commonIdentifierDescription
        desc.value = "AI-generated with \(model) via \(provider) in NEXUS AI. Prompt: \(prompt.truncated(to: 300))" as NSString
        let software = AVMutableMetadataItem()
        software.identifier = .commonIdentifierSoftware
        software.value = "NEXUS AI" as NSString
        export.metadata = [desc, software]
        export.outputURL = out
        export.outputFileType = .mp4
        let ok: Bool = await withCheckedContinuation { cont in
            export.exportAsynchronously { cont.resume(returning: export.status == .completed) }
        }
        guard ok else { return url }
        try? FileManager.default.removeItem(at: url)
        return out
    }
}
