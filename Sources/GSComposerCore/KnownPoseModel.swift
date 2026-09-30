import Foundation

/// Builds the inputs for "reconstruction from known poses" in COLMAP: a text model with fixed camera poses
/// (for `point_triangulator`) and the list of image pairs worth matching (for `matches_importer`).
public enum KnownPoseModel {
    public struct DatabaseImage: Equatable, Sendable {
        public var id: Int
        public var name: String
        public var cameraID: Int
    }

    /// COLMAP world→camera pose for an ARKit camera→world pose.
    ///
    /// ARKit: world +y up; camera x right, y up, z back. COLMAP: camera x right, y down, z forward. The world is
    /// also flipped by D = diag(1, -1, -1) so gravity points along +Y, like `model_orientation_aligner` output.
    /// With R the ARKit camera→world rotation: R_w2c = D Rᵀ D, t = -D Rᵀ p.
    public static func colmapPose(_ pose: RigidPose) -> (rotation: Quat, translation: SIMD3<Double>) {
        let d = SIMD3<Double>(1, -1, -1)
        let c0 = pose.rotation.column(0), c1 = pose.rotation.column(1), c2 = pose.rotation.column(2)
        // Rows of Rᵀ are the columns of R; D on both sides flips signs of rows 1,2 and columns 1,2.
        let rt = [c0, c1, c2]
        let rows = (0..<3).map { i in rt[i] * d * d[i] }
        let t = -SIMD3((rt[0] * pose.position).sum(), (rt[1] * pose.position).sum(), (rt[2] * pose.position).sum()) * d
        return (Quat(rows: rows[0], rows[1], rows[2]), t)
    }

    /// Parses `sqlite3 -separator '|'` output of `SELECT image_id, name, camera_id FROM images`.
    public static func parseDatabaseImages(_ text: String) -> [DatabaseImage] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 3, let id = Int(parts[0]), let cam = Int(parts[parts.count - 1]) else { return nil }
            let name = parts[1..<(parts.count - 1)].joined(separator: "|")
            return DatabaseImage(id: id, name: name, cameraID: cam)
        }
    }

    /// Writes `cameras.txt`, `images.txt` and an empty `points3D.txt`. Image and camera IDs must be the ones
    /// in the COLMAP database. Returns the number of posed images written.
    @discardableResult
    public static func write(poses: KnownPoses, databaseImages: [DatabaseImage], to directory: URL) throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let k = poses.camera
        var cameras = "# CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]\n"
        for id in Set(databaseImages.map(\.cameraID)).sorted() {
            cameras += "\(id) PINHOLE \(k.width) \(k.height) \(k.fx) \(k.fy) \(k.cx) \(k.cy)\n"
        }
        var images = "# IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME\n# POINTS2D[] as (X, Y, POINT3D_ID)\n"
        var written = 0
        for image in databaseImages.sorted(by: { $0.id < $1.id }) {
            guard let pose = poses.poses[image.name] ?? poses.poses[(image.name as NSString).lastPathComponent] else { continue }
            let p = colmapPose(pose)
            images += "\(image.id) \(p.rotation.w) \(p.rotation.x) \(p.rotation.y) \(p.rotation.z) "
                + "\(p.translation.x) \(p.translation.y) \(p.translation.z) \(image.cameraID) \(image.name)\n\n"
            written += 1
        }
        try cameras.write(to: directory.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        try images.write(to: directory.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
        try "# POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[]\n".write(
            to: directory.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)
        return written
    }

    /// Image pairs worth matching: temporal neighbours plus, for every image, the `nearest` others whose viewing
    /// directions differ by less than `maxAngle` degrees. This links the loops of a multi-height orbit (the same
    /// side is seen again minutes later) without the cost of exhaustive matching.
    /// - Parameter names: image names in capture order.
    public static func pairs(names: [String], poses: [String: RigidPose], sequential: Int = 5, nearest: Int = 15,
                             maxAngle: Double = 45) -> [(String, String)] {
        let posed = names.filter { poses[$0] != nil }
        let dirs = posed.map { poses[$0]!.forward }
        let cosMax = cos(maxAngle * .pi / 180)
        var set = Set<Int64>()
        var result: [(String, String)] = []
        func add(_ i: Int, _ j: Int) {
            let a = min(i, j), b = max(i, j)
            guard a != b, set.insert(Int64(a) << 32 | Int64(b)).inserted else { return }
            result.append((posed[a], posed[b]))
        }
        for i in posed.indices {
            for j in (i + 1)..<min(posed.count, i + 1 + sequential) { add(i, j) }
            var candidates: [(Int, Double)] = []
            for j in posed.indices where abs(j - i) > sequential {
                let c = (dirs[i] * dirs[j]).sum()
                if c >= cosMax { candidates.append((j, c)) }
            }
            candidates.sort { $0.1 > $1.1 }
            for (j, _) in candidates.prefix(nearest) { add(i, j) }
        }
        return result
    }

    public static func pairsText(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0.0) \($0.1)" }.joined(separator: "\n") + "\n"
    }
}
