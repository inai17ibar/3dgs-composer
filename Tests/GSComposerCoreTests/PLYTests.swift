import XCTest
@testable import GSComposerCore

final class PLYTests: XCTestCase {
    func testASCIIPointCloudWithRGB() throws {
        let ply = """
        ply
        format ascii 1.0
        comment test
        element vertex 2
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header
        0 1 2 255 0 0
        3 4 5 0 255 51

        """
        let cloud = try PLYReader.read(data: Data(ply.utf8))
        XCTAssertEqual(cloud.count, 2)
        XCTAssertEqual(cloud.positions, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(cloud.colors[0], 1, accuracy: 1e-6)
        XCTAssertEqual(cloud.colors[5], 0.2, accuracy: 1e-6)
        XCTAssertEqual(cloud.opacities, [1, 1])
        XCTAssertTrue(cloud.scales.allSatisfy { $0 > 0 })
        XCTAssertEqual(Array(cloud.rotations[0..<4]), [1, 0, 0, 0])
    }

    func testBinaryGaussianAttributesAreActivated() throws {
        var body = Data()
        func f(_ v: Float) { withUnsafeBytes(of: v.bitPattern.littleEndian) { body.append(contentsOf: $0) } }
        // x y z, f_dc_0..2, opacity, scale_0..2, rot_0..3
        [1, 2, 3, 0, SphericalHarmonics.colorToDC(1), SphericalHarmonics.colorToDC(0.25), 0,
         log(0.5), log(0.25), 0, 2, 0, 0, 0].forEach(f)
        let props = ["x", "y", "z", "f_dc_0", "f_dc_1", "f_dc_2", "opacity",
                     "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]
        let header = "ply\nformat binary_little_endian 1.0\nelement vertex 1\n"
            + props.map { "property float \($0)\n" }.joined() + "end_header\n"
        let cloud = try PLYReader.read(data: Data(header.utf8) + body)
        XCTAssertEqual(cloud.count, 1)
        XCTAssertEqual(cloud.position(0), SIMD3(1, 2, 3))
        XCTAssertEqual(cloud.colors[0], 0.5, accuracy: 1e-5)
        XCTAssertEqual(cloud.colors[1], 1, accuracy: 1e-5)
        XCTAssertEqual(cloud.colors[2], 0.25, accuracy: 1e-5)
        XCTAssertEqual(cloud.opacities[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(cloud.scales[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(cloud.scales[1], 0.25, accuracy: 1e-6)
        XCTAssertEqual(cloud.scales[2], 1, accuracy: 1e-6)
        XCTAssertEqual(Array(cloud.rotations), [1, 0, 0, 0])
    }

    func testBigEndianMixedTypesAndListElementBeforeVertices() throws {
        var body = Data()
        // element "meta" with a uchar-count int list, placed before vertices.
        body.append(2)
        body.append(contentsOf: [0, 0, 0, 7, 0, 0, 0, 9])
        func be(_ v: Float) { withUnsafeBytes(of: v.bitPattern.bigEndian) { body.append(contentsOf: $0) } }
        func beD(_ v: Double) { withUnsafeBytes(of: v.bitPattern.bigEndian) { body.append(contentsOf: $0) } }
        be(1); be(2); beD(3); body.append(contentsOf: [10, 20, 30])
        let header = """
        ply
        format binary_big_endian 1.0
        element meta 1
        property list uchar int values
        element vertex 1
        property float x
        property float y
        property double z
        property uchar r
        property uchar g
        property uchar b
        end_header

        """
        let cloud = try PLYReader.read(data: Data(header.utf8) + body)
        XCTAssertEqual(cloud.positions, [1, 2, 3])
        XCTAssertEqual(cloud.colors[1], 20 / 255, accuracy: 1e-6)
    }

    func testRejectsInvalidHeader() {
        XCTAssertThrowsError(try PLYReader.read(data: Data("not a ply".utf8)))
        let truncated = "ply\nformat binary_little_endian 1.0\nelement vertex 10\nproperty float x\nproperty float y\nproperty float z\nend_header\n"
        XCTAssertThrowsError(try PLYReader.read(data: Data(truncated.utf8)))
        let noXYZ = "ply\nformat ascii 1.0\nelement vertex 1\nproperty float a\nend_header\n1\n"
        XCTAssertThrowsError(try PLYReader.read(data: Data(noXYZ.utf8)))
    }

    func testGaussianPLYRoundTrip() throws {
        let cloud = GaussianCloud.sample
        let back = try PLYReader.read(data: GaussianPLYWriter.data(for: cloud))
        XCTAssertEqual(back.count, cloud.count)
        for (a, b) in zip(back.positions, cloud.positions) { XCTAssertEqual(a, b, accuracy: 1e-6) }
        for (a, b) in zip(back.scales, cloud.scales) { XCTAssertEqual(a, b, accuracy: 1e-5) }
        for (a, b) in zip(back.opacities, cloud.opacities) { XCTAssertEqual(a, b, accuracy: 1e-5) }
        for (a, b) in zip(back.colors, cloud.colors) { XCTAssertEqual(a, b, accuracy: 1e-5) }
        for (a, b) in zip(back.rotations, cloud.rotations) { XCTAssertEqual(a, b, accuracy: 1e-5) }
    }
}

extension GaussianCloud {
    static var sample: GaussianCloud {
        GaussianCloud(
            positions: [0, 0, 0, 1, 2, 3],
            scales: [0.1, 0.1, 0.1, 1, 1, 1],
            rotations: [1, 0, 0, 0, 0, 1, 0, 0],
            opacities: [0.9, 0.5],
            colors: [1, 0, 0, 0, 0.5, 1])
    }
}
