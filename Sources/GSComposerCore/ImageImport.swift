import Foundation

public enum ImageImport {
    /// Copies JPEG/PNG files into `workspace.images` with sequential names (COLMAP keys images by filename).
    /// The macOS app uses ImageIO instead so it can also decode HEIC/RAW and downscale.
    @discardableResult
    public static func copyImages(from sources: [URL], into workspace: Workspace) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: workspace.images, withIntermediateDirectories: true)
        var files: [URL] = []
        for src in sources {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)
                files += items.filter { Workspace.imageExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else if Workspace.imageExtensions.contains(src.pathExtension.lowercased()) {
                files.append(src)
            }
        }
        for (i, file) in files.enumerated() {
            let ext = file.pathExtension.lowercased() == "png" ? "png" : "jpg"
            let dest = workspace.images.appendingPathComponent(String(format: "img_%05d.%@", i, ext))
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: file, to: dest)
        }
        return files.count
    }
}
