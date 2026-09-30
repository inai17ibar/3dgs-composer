import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Imports photos (JPEG/HEIC/PNG/TIFF/RAW…) into the workspace: applies EXIF orientation, downsizes to the
/// working resolution and keeps the camera EXIF so COLMAP can use the focal length as a prior.
enum PhotoImporter {
    static func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                result += expand(items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
            } else if isImage(url) {
                result.append(url)
            }
        }
        return result
    }

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    static func isMovie(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    /// - Returns: source file name → written file name, for every image written.
    static func importPhotos(_ sources: [URL], into directory: URL, maxImageSize: Int,
                             progress: @escaping @Sendable (Double, String) -> Void) async throws -> [String: String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [String: String] = [:]
        for (i, src) in sources.enumerated() {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else { continue }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxImageSize,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
            var props: [CFString: Any] = [:]
            if let meta = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary] {
                    if let value = meta[key] { props[key] = value }
                }
            }
            if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
            props[kCGImagePropertyOrientation] = 1
            let name = String(format: "img_%05d.jpg", written.count)
            try ImageWriter.writeJPEG(image, to: directory.appendingPathComponent(name), properties: props)
            written[src.lastPathComponent] = name
            progress(Double(i + 1) / Double(sources.count), "写真 \(i + 1)/\(sources.count)")
        }
        return written
    }
}
