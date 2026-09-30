import Foundation

/// Rigid camera→world pose. Rotation columns are the camera's +x, +y, +z axes in world space.
public struct RigidPose: Codable, Equatable, Sendable {
    public var position: SIMD3<Double>
    public var rotation: Quat

    public init(position: SIMD3<Double>, rotation: Quat) {
        self.position = position
        self.rotation = rotation
    }

    /// ARKit convention: the camera looks along its local -z.
    public var forward: SIMD3<Double> { -rotation.column(2) }

    /// Linear position / spherical rotation interpolation, `t` in 0…1.
    public static func interpolate(_ a: RigidPose, _ b: RigidPose, _ t: Double) -> RigidPose {
        RigidPose(position: a.position + (b.position - a.position) * t, rotation: Quat.slerp(a.rotation, b.rotation, t))
    }
}

/// Unit quaternion (w, x, y, z).
public struct Quat: Codable, Equatable, Sendable {
    public var w, x, y, z: Double

    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w; self.x = x; self.y = y; self.z = z
    }

    /// From the rows of a rotation matrix.
    public init(rows r0: SIMD3<Double>, _ r1: SIMD3<Double>, _ r2: SIMD3<Double>) {
        let trace = r0.x + r1.y + r2.z
        var q: Quat
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            q = Quat(w: s / 4, x: (r2.y - r1.z) / s, y: (r0.z - r2.x) / s, z: (r1.x - r0.y) / s)
        } else if r0.x > r1.y && r0.x > r2.z {
            let s = (1 + r0.x - r1.y - r2.z).squareRoot() * 2
            q = Quat(w: (r2.y - r1.z) / s, x: s / 4, y: (r0.y + r1.x) / s, z: (r0.z + r2.x) / s)
        } else if r1.y > r2.z {
            let s = (1 + r1.y - r0.x - r2.z).squareRoot() * 2
            q = Quat(w: (r0.z - r2.x) / s, x: (r0.y + r1.x) / s, y: s / 4, z: (r1.z + r2.y) / s)
        } else {
            let s = (1 + r2.z - r0.x - r1.y).squareRoot() * 2
            q = Quat(w: (r1.x - r0.y) / s, x: (r0.z + r2.x) / s, y: (r1.z + r2.y) / s, z: s / 4)
        }
        if q.w < 0 { q = Quat(w: -q.w, x: -q.x, y: -q.y, z: -q.z) }
        self = q.normalized
    }

    /// From the columns of a rotation matrix.
    public init(columns c0: SIMD3<Double>, _ c1: SIMD3<Double>, _ c2: SIMD3<Double>) {
        self.init(rows: SIMD3(c0.x, c1.x, c2.x), SIMD3(c0.y, c1.y, c2.y), SIMD3(c0.z, c1.z, c2.z))
    }

    public var normalized: Quat {
        let n = (w * w + x * x + y * y + z * z).squareRoot()
        return n > 0 ? Quat(w: w / n, x: x / n, y: y / n, z: z / n) : Quat(w: 1, x: 0, y: 0, z: 0)
    }

    /// Rows of the rotation matrix.
    public var rows: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) {
        (SIMD3(1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)),
         SIMD3(2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)),
         SIMD3(2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)))
    }

    public func column(_ i: Int) -> SIMD3<Double> {
        let (r0, r1, r2) = rows
        return SIMD3(r0[i], r1[i], r2[i])
    }

    public static func slerp(_ a: Quat, _ b0: Quat, _ t: Double) -> Quat {
        var b = b0
        var d = a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z
        if d < 0 { b = Quat(w: -b.w, x: -b.x, y: -b.y, z: -b.z); d = -d }
        if d > 0.9995 {
            return Quat(w: a.w + (b.w - a.w) * t, x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, z: a.z + (b.z - a.z) * t).normalized
        }
        let theta = acos(min(d, 1))
        let s = sin(theta)
        let wa = sin((1 - t) * theta) / s, wb = sin(t * theta) / s
        return Quat(w: a.w * wa + b.w * wb, x: a.x * wa + b.x * wb, y: a.y * wa + b.y * wb, z: a.z * wa + b.z * wb)
    }
}

/// Pinhole intrinsics for an image of `width` × `height` pixels.
public struct PinholeCamera: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var fx, fy, cx, cy: Double

    public init(width: Int, height: Int, fx: Double, fy: Double, cx: Double, cy: Double) {
        self.width = width; self.height = height
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
    }

    public func scaled(toWidth w: Int, height h: Int) -> PinholeCamera {
        let sx = Double(w) / Double(width), sy = Double(h) / Double(height)
        return PinholeCamera(width: w, height: h, fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy)
    }

    /// `fx,fy,cx,cy` for `--ImageReader.camera_params` (PINHOLE).
    public var colmapParams: String { [fx, fy, cx, cy].map { String(format: "%.6f", $0) }.joined(separator: ",") }
}

/// Camera poses recorded by 3DGS Material Collector (iOS) in `manifest.json`. Poses are ARKit camera→world
/// transforms (gravity-aligned, +y up, camera looks along -z); intrinsics refer to the unrotated sensor image.
public struct ARKitCapture: Sendable, Equatable {
    public struct Frame: Sendable, Equatable {
        /// `video.mov` for video pose samples, `images/frame_00001.jpg` for photos.
        public var file: String
        /// Seconds from the start of the video (video) or from the first photo.
        public var time: Double
        public var pose: RigidPose
        public var camera: PinholeCamera
    }

    public var mode: String
    public var frames: [Frame]

    public var videoFrames: [Frame] { frames.filter { $0.file == "video.mov" }.sorted { $0.time < $1.time } }

    public static func load(_ url: URL) throws -> ARKitCapture {
        try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> ARKitCapture {
        struct Pose: Decodable { var position, right, up, back: [Double] }
        struct K: Decodable { var fx, fy, cx, cy: Double; var width, height: Int }
        struct F: Decodable { var file: String; var time: Double; var pose: Pose; var intrinsics: K }
        struct M: Decodable { var mode: String; var frames: [F] }
        let m = try JSONDecoder().decode(M.self, from: data)
        func v(_ a: [Double]) -> SIMD3<Double> { a.count >= 3 ? SIMD3(a[0], a[1], a[2]) : .zero }
        return ARKitCapture(mode: m.mode, frames: m.frames.map { f in
            Frame(file: f.file, time: f.time,
                  pose: RigidPose(position: v(f.pose.position), rotation: Quat(columns: v(f.pose.right), v(f.pose.up), v(f.pose.back))),
                  camera: PinholeCamera(width: f.intrinsics.width, height: f.intrinsics.height,
                                        fx: f.intrinsics.fx, fy: f.intrinsics.fy, cx: f.intrinsics.cx, cy: f.intrinsics.cy))
        })
    }

    /// `manifest.json` belonging to a picked input: next to the video, in the picked capture folder, or one level
    /// above an `images` folder / photo.
    public static func manifestURL(near input: URL) -> URL? {
        let fm = FileManager.default
        var dirs: [URL] = []
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: input.path, isDirectory: &isDir), isDir.boolValue { dirs.append(input) }
        let parent = input.deletingLastPathComponent()
        dirs += [parent, parent.deletingLastPathComponent()]
        return dirs.map { $0.appendingPathComponent("manifest.json") }.first { fm.fileExists(atPath: $0.path) }
    }

    /// Pose at `time` seconds into the video, interpolated between the two surrounding samples.
    /// nil when there is no sample within `maxGap` on both sides (tracking was lost there).
    public func videoPose(at time: Double, maxGap: Double = 0.3) -> (pose: RigidPose, camera: PinholeCamera)? {
        Self.interpolate(videoFrames, at: time, maxGap: maxGap)
    }

    static func interpolate(_ samples: [Frame], at time: Double, maxGap: Double) -> (pose: RigidPose, camera: PinholeCamera)? {
        guard !samples.isEmpty else { return nil }
        // First sample at or after `time`.
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        if lo < samples.count, abs(samples[lo].time - time) < 1e-6 { return (samples[lo].pose, samples[lo].camera) }
        guard lo > 0, lo < samples.count else {
            let s = lo == 0 ? samples[0] : samples[samples.count - 1]
            return abs(s.time - time) <= maxGap / 2 ? (s.pose, s.camera) : nil
        }
        let a = samples[lo - 1], b = samples[lo]
        guard b.time - a.time <= maxGap else { return nil }
        let t = (time - a.time) / (b.time - a.time)
        return (RigidPose.interpolate(a.pose, b.pose, t), t < 0.5 ? a.camera : b.camera)
    }

    /// Photo frame by file name (e.g. `frame_00001.jpg`).
    public func photo(named name: String) -> Frame? {
        frames.first { $0.file != "video.mov" && ($0.file as NSString).lastPathComponent == name }
    }
}

/// Known camera poses for the images in `workspace.images`, handed to the pipeline instead of running SfM.
public struct KnownPoses: Codable, Equatable, Sendable {
    /// Shared intrinsics at the working image size.
    public var camera: PinholeCamera
    /// ARKit camera→world pose per image file name.
    public var poses: [String: RigidPose]

    public init(camera: PinholeCamera, poses: [String: RigidPose]) {
        self.camera = camera
        self.poses = poses
    }

    /// Median intrinsics of `cameras`, rescaled to the working image size.
    public static func sharedCamera(_ cameras: [PinholeCamera], imageWidth: Int, imageHeight: Int) -> PinholeCamera? {
        let scaled = cameras.map { $0.scaled(toWidth: imageWidth, height: imageHeight) }
        guard !scaled.isEmpty else { return nil }
        func median(_ k: KeyPath<PinholeCamera, Double>) -> Double { scaled.map { $0[keyPath: k] }.sorted()[scaled.count / 2] }
        return PinholeCamera(width: imageWidth, height: imageHeight, fx: median(\.fx), fy: median(\.fy), cx: median(\.cx), cy: median(\.cy))
    }
}
