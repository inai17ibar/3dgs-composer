import Foundation

/// Writes the compact `.splat` format (antimatter15/splat, SuperSplat, Luma web viewers):
/// 32 bytes per splat — position f32x3, scale f32x3, RGBA u8x4, rotation (w,x,y,z) u8x4 as q*128+128.
/// Splats are ordered by importance (volume × opacity) so progressive loaders show the big ones first.
public enum SplatFileWriter {
    public static let bytesPerSplat = 32

    public static func data(for cloud: GaussianCloud) -> Data {
        let n = cloud.count
        var importance = [Float](repeating: 0, count: n)
        for i in 0..<n {
            importance[i] = cloud.scales[i * 3] * cloud.scales[i * 3 + 1] * cloud.scales[i * 3 + 2] * cloud.opacities[i]
        }
        let order = (0..<n).sorted { importance[$0] > importance[$1] }

        var out = Data(count: n * bytesPerSplat)
        out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for (k, i) in order.enumerated() {
                let base = k * bytesPerSplat
                for a in 0..<3 {
                    raw.storeBytes(of: cloud.positions[i * 3 + a], toByteOffset: base + a * 4, as: Float.self)
                    raw.storeBytes(of: cloud.scales[i * 3 + a], toByteOffset: base + 12 + a * 4, as: Float.self)
                }
                for a in 0..<3 {
                    raw.storeBytes(of: toByte(cloud.colors[i * 3 + a] * 255), toByteOffset: base + 24 + a, as: UInt8.self)
                }
                raw.storeBytes(of: toByte(cloud.opacities[i] * 255), toByteOffset: base + 27, as: UInt8.self)
                for a in 0..<4 {
                    raw.storeBytes(of: toByte(cloud.rotations[i * 4 + a] * 128 + 128), toByteOffset: base + 28 + a, as: UInt8.self)
                }
            }
        }
        return out
    }

    public static func write(_ cloud: GaussianCloud, to url: URL) throws {
        try data(for: cloud).write(to: url, options: .atomic)
    }

    @inline(__always) private static func toByte(_ v: Float) -> UInt8 {
        UInt8(min(max(v.rounded(), 0), 255))
    }
}

/// Writes a standard 3DGS PLY (SH degree 0) that every splat tool can read.
public enum GaussianPLYWriter {
    static let properties = [
        "x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2", "opacity",
        "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"
    ]

    public static func data(for cloud: GaussianCloud) -> Data {
        var header = "ply\nformat binary_little_endian 1.0\nelement vertex \(cloud.count)\n"
        for p in properties { header += "property float \(p)\n" }
        header += "end_header\n"
        var out = Data(header.utf8)
        let stride = properties.count * 4
        var body = Data(count: cloud.count * stride)
        body.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for i in 0..<cloud.count {
                var values: [Float] = [
                    cloud.positions[i * 3], cloud.positions[i * 3 + 1], cloud.positions[i * 3 + 2], 0, 0, 0,
                    SphericalHarmonics.colorToDC(cloud.colors[i * 3]),
                    SphericalHarmonics.colorToDC(cloud.colors[i * 3 + 1]),
                    SphericalHarmonics.colorToDC(cloud.colors[i * 3 + 2]),
                    inverseSigmoid(cloud.opacities[i])
                ]
                for a in 0..<3 { values.append(log(max(cloud.scales[i * 3 + a], 1e-12))) }
                for a in 0..<4 { values.append(cloud.rotations[i * 4 + a]) }
                for (k, v) in values.enumerated() {
                    raw.storeBytes(of: v.bitPattern.littleEndian, toByteOffset: i * stride + k * 4, as: UInt32.self)
                }
            }
        }
        out.append(body)
        return out
    }

    public static func write(_ cloud: GaussianCloud, to url: URL) throws {
        try data(for: cloud).write(to: url, options: .atomic)
    }
}

/// Reads the compact `.splat` format written by `SplatFileWriter`.
public enum SplatFileReader {
    public static func read(url: URL) throws -> GaussianCloud {
        try read(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func read(data: Data) throws -> GaussianCloud {
        let stride = SplatFileWriter.bytesPerSplat
        guard data.count % stride == 0 else { throw PLYError.truncated }
        let n = data.count / stride
        var positions = [Float](repeating: 0, count: n * 3)
        var scales = [Float](repeating: 0, count: n * 3)
        var rotations = [Float](repeating: 0, count: n * 4)
        var opacities = [Float](repeating: 0, count: n)
        var colors = [Float](repeating: 0, count: n * 3)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let base = i * stride
                for a in 0..<3 {
                    positions[i * 3 + a] = raw.loadUnaligned(fromByteOffset: base + a * 4, as: Float.self)
                    scales[i * 3 + a] = raw.loadUnaligned(fromByteOffset: base + 12 + a * 4, as: Float.self)
                    colors[i * 3 + a] = Float(raw[base + 24 + a]) / 255
                }
                opacities[i] = Float(raw[base + 27]) / 255
                var q = SIMD4<Float>((0..<4).map { (Float(raw[base + 28 + $0]) - 128) / 128 })
                let len = (q * q).sum().squareRoot()
                q = len > 0 ? q / len : SIMD4(1, 0, 0, 0)
                for a in 0..<4 { rotations[i * 4 + a] = q[a] }
            }
        }
        return GaussianCloud(positions: positions, scales: scales, rotations: rotations, opacities: opacities, colors: colors)
    }
}

public enum SplatLoader {
    /// Loads `.ply` (3DGS or plain point cloud) or `.splat`.
    public static func load(url: URL) throws -> GaussianCloud {
        url.pathExtension.lowercased() == "splat" ? try SplatFileReader.read(url: url) : try PLYReader.read(url: url)
    }
}
