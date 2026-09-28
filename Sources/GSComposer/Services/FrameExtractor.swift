import AVFoundation
import CoreGraphics
import Foundation
import GSComposerCore
import ImageIO
import UniformTypeIdentifiers

/// Picks well-distributed, sharp still frames from a video and writes them as JPEGs for COLMAP.
enum FrameExtractor {
    struct Options {
        var targetCount: Int
        var pickSharpest: Bool
        var maxImageSize: Int
    }

    enum ExtractionError: LocalizedError {
        case noVideoTrack
        case noFrames

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "動画トラックが見つかりません。"
            case .noFrames: return "動画からフレームを取り出せませんでした。"
            }
        }
    }

    /// - Returns: number of frames written.
    static func extract(video: URL, into directory: URL, options: Options,
                        progress: @escaping @Sendable (Double, String) -> Void) async throws -> Int {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExtractionError.noVideoTrack }
        let fps = Double(try await track.load(.nominalFrameRate))
        let totalFrames = max(1, Int(duration * (fps > 0 ? fps : 30)))
        let target = min(options.targetCount, totalFrames)

        var times: [CMTime]
        if options.pickSharpest {
            // Pass 1: score ~3 candidates per output frame on small thumbnails.
            let candidates = FrameSelection.sampleTimes(duration: duration, count: min(target * 3, totalFrames))
            let slot = duration / Double(max(candidates.count, 1))
            let scorer = AVAssetImageGenerator(asset: asset)
            scorer.appliesPreferredTrackTransform = true
            scorer.maximumSize = CGSize(width: 480, height: 480)
            scorer.requestedTimeToleranceBefore = CMTime(seconds: slot / 2, preferredTimescale: 600)
            scorer.requestedTimeToleranceAfter = CMTime(seconds: slot / 2, preferredTimescale: 600)
            var scores: [Double] = []
            var actual: [CMTime] = []
            for (i, t) in candidates.enumerated() {
                try Task.checkCancellation()
                guard let frame = try? await scorer.image(at: CMTime(seconds: t, preferredTimescale: 600)) else { continue }
                scores.append(sharpness(frame.image))
                actual.append(frame.actualTime)
                progress(Double(i + 1) / Double(candidates.count) * 0.5, "ブレ判定 \(i + 1)/\(candidates.count)")
            }
            times = FrameSelection.pickSharpest(scores: scores, targetCount: target).map { actual[$0] }
        } else {
            times = FrameSelection.sampleTimes(duration: duration, count: target).map { CMTime(seconds: $0, preferredTimescale: 600) }
        }

        // Pass 2: decode the chosen frames at working resolution.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: options.maxImageSize, height: options.maxImageSize)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written = 0
        let base = options.pickSharpest ? 0.5 : 0
        for (i, t) in times.enumerated() {
            try Task.checkCancellation()
            guard let frame = try? await generator.image(at: t) else { continue }
            let url = directory.appendingPathComponent(String(format: "frame_%05d.jpg", written))
            try ImageWriter.writeJPEG(frame.image, to: url, properties: nil)
            written += 1
            progress(base + Double(i + 1) / Double(times.count) * (1 - base), "フレーム書き出し \(i + 1)/\(times.count)")
        }
        guard written > 0 else { throw ExtractionError.noFrames }
        return written
    }

    static func sharpness(_ image: CGImage) -> Double {
        let w = image.width, h = image.height
        guard w >= 3, h >= 3,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let gray = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: ctx.bytesPerRow * h))
        return FrameSelection.laplacianVariance(gray: gray, width: w, height: h, bytesPerRow: ctx.bytesPerRow)
    }
}

enum ImageWriter {
    static func writeJPEG(_ image: CGImage, to url: URL, properties: [CFString: Any]?) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var props = properties ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = 0.95
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
