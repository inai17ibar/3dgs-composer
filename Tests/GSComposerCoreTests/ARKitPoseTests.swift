import Foundation
import XCTest
@testable import GSComposerCore

/// ARKit-style camera at `eye` looking at `target` (camera -z forward, +y up).
private func looking(from eye: SIMD3<Double>, at target: SIMD3<Double>) -> RigidPose {
    func norm(_ v: SIMD3<Double>) -> SIMD3<Double> { v / ((v * v).sum()).squareRoot() }
    func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
    let f = norm(target - eye)
    let r = norm(cross(f, SIMD3(0, 1, 0)))
    let u = cross(r, f)
    return RigidPose(position: eye, rotation: Quat(columns: r, u, -f))
}

private func orbit(azimuth: Double, elevation: Double, radius: Double = 1) -> RigidPose {
    let az = azimuth * .pi / 180, el = elevation * .pi / 180
    return looking(from: radius * SIMD3(cos(el) * sin(az), sin(el), cos(el) * cos(az)), at: .zero)
}

private func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ eps: Double = 1e-6) -> Bool {
    ((a - b) * (a - b)).sum().squareRoot() < eps
}

final class ARKitPoseTests: XCTestCase {
    func testQuaternionRoundTrip() {
        let p = looking(from: SIMD3(0.3, 1.2, -0.7), at: SIMD3(0.1, 0, 0.2))
        let (r0, r1, r2) = p.rotation.rows
        XCTAssertEqual(Quat(rows: r0, r1, r2), p.rotation)
        XCTAssertEqual((p.forward * p.forward).sum(), 1, accuracy: 1e-9)
        XCTAssertTrue(close(p.forward, (SIMD3(0.1, 0, 0.2) - p.position) / ((SIMD3(0.1, 0, 0.2) - p.position) * (SIMD3(0.1, 0, 0.2) - p.position)).sum().squareRoot()))
    }

    func testSlerpHalfway() {
        let a = orbit(azimuth: 0, elevation: 0), b = orbit(azimuth: 90, elevation: 0)
        let m = RigidPose.interpolate(a, b, 0.5)
        let expected = orbit(azimuth: 45, elevation: 0)
        XCTAssertTrue(close(m.forward, expected.forward, 1e-6))
        XCTAssertTrue(close(m.position, (a.position + b.position) / 2))
    }

    /// The subject centre must project to the principal point, in front of the camera, with gravity along +Y.
    func testColmapPoseProjectsTargetOnAxis() {
        let target = SIMD3<Double>(0.2, 0.1, -0.3)
        let pose = looking(from: SIMD3(1.0, 0.8, 0.5), at: target)
        let (q, t) = KnownPoseModel.colmapPose(pose)
        let (r0, r1, r2) = q.rows
        let world = target * SIMD3(1, -1, -1)
        let cam = SIMD3((r0 * world).sum(), (r1 * world).sum(), (r2 * world).sum()) + t
        XCTAssertEqual(cam.x, 0, accuracy: 1e-9)
        XCTAssertEqual(cam.y, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(cam.z, 0)
        // A point above the target (ARKit +y) appears higher in the image: smaller COLMAP camera y.
        let above = (target + SIMD3(0, 0.1, 0)) * SIMD3(1, -1, -1)
        let camAbove = SIMD3((r0 * above).sum(), (r1 * above).sum(), (r2 * above).sum()) + t
        XCTAssertLessThan(camAbove.y, 0)
    }

    func testDecodeMaterialCollectorManifest() throws {
        // Shape written by the iOS app: SIMD3<Float> vectors encode as arrays.
        let json = """
        {"version":2,"mode":"video","subject":"small","center":[0,0,0],"coverage":1,"createdAt":"2026-09-30T00:00:00Z",
         "device":"iPhone","video":"video.mov","frames":[
          {"file":"video.mov","time":0.0,"pose":{"position":[0,0,1],"right":[1,0,0],"up":[0,1,0],"back":[0,0,1]},
           "intrinsics":{"fx":2800,"fy":2800,"cx":1920,"cy":1080,"width":3840,"height":2160},"sharpness":120},
          {"file":"video.mov","time":0.1,"pose":{"position":[0.1,0,1],"right":[1,0,0],"up":[0,1,0],"back":[0,0,1]},
           "intrinsics":{"fx":2800,"fy":2800,"cx":1920,"cy":1080,"width":3840,"height":2160}},
          {"file":"video.mov","time":1.0,"pose":{"position":[1,0,1],"right":[1,0,0],"up":[0,1,0],"back":[0,0,1]},
           "intrinsics":{"fx":2800,"fy":2800,"cx":1920,"cy":1080,"width":3840,"height":2160}}]}
        """
        let capture = try ARKitCapture.decode(Data(json.utf8))
        XCTAssertEqual(capture.mode, "video")
        XCTAssertEqual(capture.videoFrames.count, 3)
        XCTAssertTrue(close(capture.frames[0].pose.forward, SIMD3(0, 0, -1)))

        let mid = try XCTUnwrap(capture.videoPose(at: 0.05))
        XCTAssertEqual(mid.pose.position.x, 0.05, accuracy: 1e-9)
        XCTAssertNil(capture.videoPose(at: 0.5), "0.9 s gap: tracking was lost there")
        XCTAssertNotNil(capture.videoPose(at: 1.1), "just past the last sample")
        XCTAssertNil(capture.videoPose(at: 3))

        let k = KnownPoses.sharedCamera(capture.frames.map(\.camera), imageWidth: 1600, imageHeight: 900)
        XCTAssertEqual(k?.fx ?? 0, 2800 * 1600 / 3840, accuracy: 1e-9)
        XCTAssertEqual(k?.cy ?? 0, 450, accuracy: 1e-9)
        XCTAssertEqual(k?.colmapParams, "1166.666667,1166.666667,800.000000,450.000000")
    }

    func testPairsLinkLoopsAtDifferentHeights() {
        // Two loops around the subject, 72 frames each (5° apart), 30° apart in elevation.
        var names: [String] = []
        var poses: [String: RigidPose] = [:]
        for (loop, el) in [0.0, 30.0].enumerated() {
            for i in 0..<72 {
                let name = String(format: "frame_%05d.jpg", loop * 72 + i)
                names.append(name)
                poses[name] = orbit(azimuth: Double(i) * 5, elevation: el)
            }
        }
        let pairs = KnownPoseModel.pairs(names: names, poses: poses, sequential: 5, nearest: 10, maxAngle: 45)
        let set = Set(pairs.map { "\($0.0) \($0.1)" })
        XCTAssertTrue(set.contains("frame_00000.jpg frame_00001.jpg"))
        XCTAssertTrue(pairs.contains { a, b in
            let i = Int(a.dropFirst(6).prefix(5))!, j = Int(b.dropFirst(6).prefix(5))!
            return (i < 72) != (j < 72)
        }, "loops must be matched against each other")
        XCTAssertFalse(set.contains("frame_00000.jpg frame_00036.jpg"), "opposite sides are never paired")
        XCTAssertEqual(set.count, pairs.count, "no duplicates")
        XCTAssertLessThan(pairs.count, names.count * (names.count - 1) / 2 / 5, "far fewer than exhaustive")
    }

    func testDatabaseParsingAndModelText() throws {
        let rows = KnownPoseModel.parseDatabaseImages("1|frame_00000.jpg|1\n2|frame_00001.jpg|1\n3|no_pose.jpg|1\ngarbage\n")
        XCTAssertEqual(rows.map(\.id), [1, 2, 3])
        XCTAssertEqual(rows[1].name, "frame_00001.jpg")

        let known = KnownPoses(camera: PinholeCamera(width: 1600, height: 900, fx: 1000, fy: 1000, cx: 800, cy: 450),
                               poses: ["frame_00000.jpg": orbit(azimuth: 0, elevation: 0),
                                       "frame_00001.jpg": orbit(azimuth: 10, elevation: 0)])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(try KnownPoseModel.write(poses: known, databaseImages: rows, to: dir), 2)
        let cameras = try String(contentsOf: dir.appendingPathComponent("cameras.txt"), encoding: .utf8)
        XCTAssertTrue(cameras.contains("1 PINHOLE 1600 900 1000.0 1000.0 800.0 450.0"))
        let images = try String(contentsOf: dir.appendingPathComponent("images.txt"), encoding: .utf8)
        let lines = images.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasPrefix("2 ") && lines[1].hasSuffix(" 1 frame_00001.jpg"))
        XCTAssertTrue(images.contains("frame_00001.jpg\n\n"), "empty POINTS2D line after each image")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("points3D.txt").path))
    }

    func testKnownPoseCommands() {
        let ws = Workspace(root: URL(fileURLWithPath: "/tmp/ws"))
        let caps = ColmapCapabilities(
            commands: [], featureExtractor: ColmapOptionSet(names: ["FeatureExtraction.use_gpu"]),
            sequentialMatcher: ColmapOptionSet(names: []), exhaustiveMatcher: ColmapOptionSet(names: []),
            mapper: ColmapOptionSet(names: []), globalMapper: ColmapOptionSet(names: []), imageUndistorter: ColmapOptionSet(names: []),
            matchesImporter: ColmapOptionSet(names: ["FeatureMatching.use_gpu"]),
            pointTriangulator: ColmapOptionSet(names: ["clear_points", "refine_intrinsics", "Mapper.ba_refine_focal_length"]),
            bundleAdjuster: ColmapOptionSet(names: ["BundleAdjustment.refine_focal_length"]))
        let b = ColmapCommandBuilder(colmap: URL(fileURLWithPath: "/bin/colmap"), glomap: nil, capabilities: caps,
                                     settings: PipelineSettings(), workspace: ws, input: .video)
        let k = PinholeCamera(width: 1600, height: 900, fx: 1000, fy: 1000, cx: 800, cy: 450)
        let fe = b.featureExtraction(knownCamera: k).arguments
        XCTAssertEqual(fe[fe.firstIndex(of: "--ImageReader.camera_model")! + 1], "PINHOLE")
        XCTAssertEqual(fe[fe.firstIndex(of: "--ImageReader.camera_params")! + 1], k.colmapParams)
        XCTAssertEqual(fe.filter { $0 == "--ImageReader.camera_model" }.count, 1)

        let mi = b.pairMatching(listPath: ws.pairsList).arguments
        XCTAssertEqual(Array(mi.prefix(1)), ["matches_importer"])
        XCTAssertTrue(mi.contains(ws.pairsList.path))
        XCTAssertTrue(mi.contains("--FeatureMatching.use_gpu"))

        let pt = b.pointTriangulation(input: ws.knownModel, output: ws.triangulatedModel).arguments
        XCTAssertEqual(pt.first, "point_triangulator")
        XCTAssertTrue(pt.contains("--clear_points") && pt.contains("--Mapper.ba_refine_focal_length"))
        XCTAssertFalse(pt.contains("--Mapper.ba_refine_extra_params"), "unsupported options are omitted")

        let ba = b.bundleAdjustment(input: ws.triangulatedModel, output: ws.sparse).arguments
        XCTAssertEqual(ba.first, "bundle_adjuster")
        XCTAssertTrue(ba.contains("--BundleAdjustment.refine_focal_length"))
    }
}
