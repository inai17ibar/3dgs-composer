import Foundation

public enum PLYError: Error, LocalizedError, Equatable {
    case notPLY
    case unsupportedFormat(String)
    case missingVertexElement
    case missingProperty(String)
    case truncated
    case malformedHeader(String)

    public var errorDescription: String? {
        switch self {
        case .notPLY: return "PLY ファイルではありません"
        case .unsupportedFormat(let f): return "未対応の PLY 形式です: \(f)"
        case .missingVertexElement: return "vertex 要素がありません"
        case .missingProperty(let p): return "必須プロパティがありません: \(p)"
        case .truncated: return "PLY ファイルが途中で切れています"
        case .malformedHeader(let l): return "PLY ヘッダが不正です: \(l)"
        }
    }
}

public struct PLYHeader: Equatable, Sendable {
    public enum Format: String, Sendable { case ascii, binaryLittleEndian = "binary_little_endian", binaryBigEndian = "binary_big_endian" }

    public enum ScalarType: String, Sendable {
        case int8, uint8, int16, uint16, int32, uint32, float32, float64

        init?(plyName: String) {
            switch plyName {
            case "char", "int8": self = .int8
            case "uchar", "uint8": self = .uint8
            case "short", "int16": self = .int16
            case "ushort", "uint16": self = .uint16
            case "int", "int32": self = .int32
            case "uint", "uint32": self = .uint32
            case "float", "float32": self = .float32
            case "double", "float64": self = .float64
            default: return nil
            }
        }

        public var size: Int {
            switch self {
            case .int8, .uint8: return 1
            case .int16, .uint16: return 2
            case .int32, .uint32, .float32: return 4
            case .float64: return 8
            }
        }
    }

    public struct Property: Equatable, Sendable {
        public var name: String
        public var type: ScalarType
        /// Non-nil for `property list <countType> <type> name`.
        public var listCountType: ScalarType?
    }

    public struct Element: Equatable, Sendable {
        public var name: String
        public var count: Int
        public var properties: [Property]

        /// Byte size of one record, or nil when the element has list properties.
        public var fixedStride: Int? {
            var s = 0
            for p in properties {
                if p.listCountType != nil { return nil }
                s += p.type.size
            }
            return s
        }
    }

    public var format: Format
    public var elements: [Element]
    /// Byte offset of the first data byte after `end_header\n`.
    public var dataOffset: Int

    public static func parse(_ data: Data) throws -> PLYHeader {
        let marker = Array("end_header".utf8)
        let limit = min(data.count, 1 << 20)
        var endIndex: Int?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard limit >= marker.count else { return }
            var i = 0
            while i <= limit - marker.count {
                if bytes[i] == marker[0] {
                    var match = true
                    for k in 1..<marker.count where bytes[i + k] != marker[k] { match = false; break }
                    if match { endIndex = i; return }
                }
                i += 1
            }
        }
        guard let end = endIndex else { throw PLYError.notPLY }
        var offset = end + marker.count
        // Skip the line terminator (\n or \r\n).
        while offset < data.count, data[data.startIndex + offset] == 0x0D || data[data.startIndex + offset] == 0x0A {
            let isLF = data[data.startIndex + offset] == 0x0A
            offset += 1
            if isLF { break }
        }
        guard let text = String(data: data.prefix(end), encoding: .ascii) else { throw PLYError.notPLY }
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "ply" else { throw PLYError.notPLY }

        var format: Format?
        var elements: [Element] = []
        for line in lines.dropFirst() where !line.isEmpty {
            let parts = line.split(separator: " ").map(String.init)
            switch parts[0] {
            case "format":
                guard parts.count >= 2 else { throw PLYError.malformedHeader(line) }
                guard let f = Format(rawValue: parts[1]) else { throw PLYError.unsupportedFormat(parts[1]) }
                format = f
            case "element":
                guard parts.count == 3, let n = Int(parts[2]) else { throw PLYError.malformedHeader(line) }
                elements.append(Element(name: parts[1], count: n, properties: []))
            case "property":
                guard !elements.isEmpty else { throw PLYError.malformedHeader(line) }
                if parts.count == 5, parts[1] == "list" {
                    guard let ct = ScalarType(plyName: parts[2]), let t = ScalarType(plyName: parts[3]) else {
                        throw PLYError.malformedHeader(line)
                    }
                    elements[elements.count - 1].properties.append(Property(name: parts[4], type: t, listCountType: ct))
                } else if parts.count == 3, let t = ScalarType(plyName: parts[1]) {
                    elements[elements.count - 1].properties.append(Property(name: parts[2], type: t, listCountType: nil))
                } else {
                    throw PLYError.malformedHeader(line)
                }
            case "comment", "obj_info":
                continue
            default:
                throw PLYError.malformedHeader(line)
            }
        }
        guard let fmt = format else { throw PLYError.malformedHeader("format がありません") }
        return PLYHeader(format: fmt, elements: elements, dataOffset: offset)
    }
}

/// Reads 3DGS-style PLY files (as written by the INRIA reference, gsplat, Brush, OpenSplat, nerfstudio)
/// and falls back to plain coloured point clouds (x, y, z, red, green, blue).
public enum PLYReader {
    public static func read(url: URL) throws -> GaussianCloud {
        try read(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func read(data: Data) throws -> GaussianCloud {
        let header = try PLYHeader.parse(data)
        guard let vertexIndex = header.elements.firstIndex(where: { $0.name == "vertex" }) else {
            throw PLYError.missingVertexElement
        }
        let vertex = header.elements[vertexIndex]
        let columns = try readColumns(data: data, header: header, vertexIndex: vertexIndex)
        return try makeCloud(vertex: vertex, columns: columns)
    }

    /// Returns one Float column per vertex property (list properties are skipped).
    static func readColumns(data: Data, header: PLYHeader, vertexIndex: Int) throws -> [String: [Float]] {
        let vertex = header.elements[vertexIndex]
        let n = vertex.count
        let scalarProps = vertex.properties.filter { $0.listCountType == nil }
        var columns = [[Float]](repeating: [Float](repeating: 0, count: n), count: scalarProps.count)

        switch header.format {
        case .ascii:
            guard let body = String(data: data.suffix(from: data.startIndex + header.dataOffset), encoding: .ascii) else {
                throw PLYError.truncated
            }
            var lines = body.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).makeIterator()
            for element in header.elements.prefix(vertexIndex) {
                for _ in 0..<element.count { _ = lines.next() }
            }
            for row in 0..<n {
                guard let line = lines.next() else { throw PLYError.truncated }
                let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
                var t = 0
                var col = 0
                for p in vertex.properties {
                    if p.listCountType != nil {
                        guard t < tokens.count, let c = Int(tokens[t]) else { throw PLYError.truncated }
                        t += 1 + c
                        continue
                    }
                    guard t < tokens.count, let v = Float(tokens[t]) else { throw PLYError.truncated }
                    columns[col][row] = v
                    col += 1
                    t += 1
                }
            }
        case .binaryLittleEndian, .binaryBigEndian:
            let bigEndian = header.format == .binaryBigEndian
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var cursor = header.dataOffset
                for element in header.elements.prefix(vertexIndex) {
                    cursor = try skip(element: element, raw: raw, cursor: cursor, bigEndian: bigEndian)
                }
                if let stride = vertex.fixedStride {
                    guard cursor + stride * n <= raw.count else { throw PLYError.truncated }
                    var offsets: [Int] = []
                    var o = 0
                    for p in scalarProps { offsets.append(o); o += p.type.size }
                    let allFloatLE = !bigEndian && scalarProps.allSatisfy { $0.type == .float32 }
                    for row in 0..<n {
                        let base = cursor + row * stride
                        if allFloatLE {
                            for c in 0..<scalarProps.count {
                                columns[c][row] = raw.loadUnaligned(fromByteOffset: base + offsets[c], as: Float.self)
                            }
                        } else {
                            for c in 0..<scalarProps.count {
                                columns[c][row] = readScalar(raw, base + offsets[c], scalarProps[c].type, bigEndian)
                            }
                        }
                    }
                } else {
                    for row in 0..<n {
                        var col = 0
                        for p in vertex.properties {
                            if let ct = p.listCountType {
                                guard cursor + ct.size <= raw.count else { throw PLYError.truncated }
                                let c = Int(readScalar(raw, cursor, ct, bigEndian))
                                cursor += ct.size + c * p.type.size
                                continue
                            }
                            guard cursor + p.type.size <= raw.count else { throw PLYError.truncated }
                            columns[col][row] = readScalar(raw, cursor, p.type, bigEndian)
                            cursor += p.type.size
                            col += 1
                        }
                    }
                }
            }
        }

        var result: [String: [Float]] = [:]
        for (i, p) in scalarProps.enumerated() { result[p.name] = columns[i] }
        return result
    }

    private static func skip(element: PLYHeader.Element, raw: UnsafeRawBufferPointer, cursor: Int, bigEndian: Bool) throws -> Int {
        if let stride = element.fixedStride { return cursor + stride * element.count }
        var c = cursor
        for _ in 0..<element.count {
            for p in element.properties {
                if let ct = p.listCountType {
                    guard c + ct.size <= raw.count else { throw PLYError.truncated }
                    let n = Int(readScalar(raw, c, ct, bigEndian))
                    c += ct.size + n * p.type.size
                } else {
                    c += p.type.size
                }
            }
        }
        return c
    }

    @inline(__always)
    static func readScalar(_ raw: UnsafeRawBufferPointer, _ offset: Int, _ type: PLYHeader.ScalarType, _ bigEndian: Bool) -> Float {
        switch type {
        case .int8: return Float(raw.loadUnaligned(fromByteOffset: offset, as: Int8.self))
        case .uint8: return Float(raw.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
        case .int16:
            let v = raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)
            return Float(bigEndian ? Int16(bigEndian: v) : Int16(littleEndian: v))
        case .uint16:
            let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            return Float(bigEndian ? UInt16(bigEndian: v) : UInt16(littleEndian: v))
        case .int32:
            let v = raw.loadUnaligned(fromByteOffset: offset, as: Int32.self)
            return Float(bigEndian ? Int32(bigEndian: v) : Int32(littleEndian: v))
        case .uint32:
            let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            return Float(bigEndian ? UInt32(bigEndian: v) : UInt32(littleEndian: v))
        case .float32:
            let bits = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            return Float(bitPattern: bigEndian ? UInt32(bigEndian: bits) : UInt32(littleEndian: bits))
        case .float64:
            let bits = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            return Float(Double(bitPattern: bigEndian ? UInt64(bigEndian: bits) : UInt64(littleEndian: bits)))
        }
    }

    static func makeCloud(vertex: PLYHeader.Element, columns: [String: [Float]]) throws -> GaussianCloud {
        let n = vertex.count
        guard let x = columns["x"], let y = columns["y"], let z = columns["z"] else {
            throw PLYError.missingProperty("x / y / z")
        }
        var positions = [Float](repeating: 0, count: n * 3)
        for i in 0..<n {
            positions[i * 3] = x[i]; positions[i * 3 + 1] = y[i]; positions[i * 3 + 2] = z[i]
        }

        var colors = [Float](repeating: 0.8, count: n * 3)
        if let r = columns["f_dc_0"], let g = columns["f_dc_1"], let b = columns["f_dc_2"] {
            for i in 0..<n {
                colors[i * 3] = SphericalHarmonics.dcToColor(r[i])
                colors[i * 3 + 1] = SphericalHarmonics.dcToColor(g[i])
                colors[i * 3 + 2] = SphericalHarmonics.dcToColor(b[i])
            }
        } else if let r = columns["red"] ?? columns["r"], let g = columns["green"] ?? columns["g"], let b = columns["blue"] ?? columns["b"] {
            let type = vertex.properties.first(where: { $0.name == "red" || $0.name == "r" })?.type
            let divisor: Float = (type == .float32 || type == .float64) ? 1 : 255
            for i in 0..<n {
                colors[i * 3] = r[i] / divisor
                colors[i * 3 + 1] = g[i] / divisor
                colors[i * 3 + 2] = b[i] / divisor
            }
        }
        for i in 0..<colors.count { colors[i] = min(max(colors[i], 0), 1) }

        var opacities = [Float](repeating: 1, count: n)
        if let o = columns["opacity"] {
            for i in 0..<n { opacities[i] = sigmoid(o[i]) }
        }

        var scales = [Float](repeating: 0, count: n * 3)
        if let s0 = columns["scale_0"], let s1 = columns["scale_1"], let s2 = columns["scale_2"] {
            for i in 0..<n {
                scales[i * 3] = exp(s0[i]); scales[i * 3 + 1] = exp(s1[i]); scales[i * 3 + 2] = exp(s2[i])
            }
        } else {
            // Plain point cloud: isotropic splats sized relative to the scene extent.
            let tmp = GaussianCloud(positions: positions, scales: scales, rotations: [Float](repeating: 0, count: n * 4),
                                    opacities: opacities, colors: colors)
            let radius = tmp.robustBounds().radius
            let s = radius / max(Float(n).squareRoot(), 1) * 0.5
            for i in 0..<scales.count { scales[i] = max(s, 1e-4) }
        }

        var rotations = [Float](repeating: 0, count: n * 4)
        if let r0 = columns["rot_0"], let r1 = columns["rot_1"], let r2 = columns["rot_2"], let r3 = columns["rot_3"] {
            for i in 0..<n {
                var q = SIMD4(r0[i], r1[i], r2[i], r3[i])
                let len = (q * q).sum().squareRoot()
                q = len > 0 ? q / len : SIMD4(1, 0, 0, 0)
                rotations[i * 4] = q.x; rotations[i * 4 + 1] = q.y; rotations[i * 4 + 2] = q.z; rotations[i * 4 + 3] = q.w
            }
        } else {
            for i in 0..<n { rotations[i * 4] = 1 }
        }

        return GaussianCloud(positions: positions, scales: scales, rotations: rotations, opacities: opacities, colors: colors)
    }
}
