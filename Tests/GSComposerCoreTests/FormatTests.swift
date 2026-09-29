import XCTest
@testable import GSComposerCore

final class SplatFormatTests: XCTestCase {
    func testSplatRecordsAreSortedByImportanceAndEncoded() {
        let data = SplatFileWriter.data(for: .sample)
        XCTAssertEqual(data.count, 64)
        // Second splat has volume 1 × opacity 0.5, which beats 0.001 × 0.9, so it comes first.
        func float(_ offset: Int) -> Float {
            Float(bitPattern: data[offset..<offset + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) })
        }
        XCTAssertEqual(float(0), 1)
        XCTAssertEqual(float(8), 3)
        XCTAssertEqual(float(12), 1)
        XCTAssertEqual(Array(data[24..<28]), [0, 128, 255, 128])
        XCTAssertEqual(Array(data[28..<32]), [128, 255, 128, 128])
        XCTAssertEqual(Array(data[32 + 24..<32 + 28]), [255, 0, 0, 230])
    }

    func testDepthSortIsBackToFront() {
        let positions: [Float] = [0, 0, 5, 0, 0, 1, 0, 0, 10, 0, 0, 3]
        let order = DepthSorter.backToFront(positions: positions, cameraPosition: .zero, forward: SIMD3(0, 0, 1))
        XCTAssertEqual(order, [2, 0, 3, 1])
        XCTAssertEqual(DepthSorter.backToFront(positions: [], cameraPosition: .zero, forward: SIMD3(0, 0, 1)), [])
    }

    func testRobustBoundsIgnoresOutliers() {
        var positions: [Float] = []
        for i in 0..<99 { positions += [Float(i % 3) - 1, 0, 0] }
        positions += [1000, 1000, 1000]
        let n = positions.count / 3
        let cloud = GaussianCloud(positions: positions, scales: .init(repeating: 1, count: n * 3),
                                  rotations: (0..<n).flatMap { _ in [Float(1), 0, 0, 0] },
                                  opacities: .init(repeating: 1, count: n), colors: .init(repeating: 1, count: n * 3))
        let b = cloud.robustBounds()
        XCTAssertEqual(b.center, SIMD3(0, 0, 0))
        XCTAssertLessThan(b.radius, 5)
    }
}

final class ParserTests: XCTestCase {
    func testColmapProgress() {
        XCTAssertEqual(ProgressParser.colmapFraction("Processed file [12/48]")!, 0.25, accuracy: 1e-9)
        XCTAssertEqual(ProgressParser.colmapFraction("Matching block [2/2, 1/2]")!, 0.75, accuracy: 1e-9)
        XCTAssertNil(ProgressParser.colmapFraction("Elapsed time: 0.1 [minutes]"))
        XCTAssertEqual(ProgressParser.mapperRegisteredCount("Registering image #12 (13)"), 13)
        XCTAssertNil(ProgressParser.mapperRegisteredCount("Bundle adjustment"))
    }

    func testTrainingStep() {
        XCTAssertEqual(ProgressParser.trainingStep("Step 1200: 0.0312 (4%)"), 1200)
        XCTAssertEqual(ProgressParser.trainingStep("Training step 50/30000"), 50)
        XCTAssertEqual(ProgressParser.trainingStep("iter=77 loss=0.1"), 77)
        XCTAssertNil(ProgressParser.trainingStep("Loading dataset"))
        XCTAssertNil(ProgressParser.trainingStep("total steps unknown"))
    }

    func testLineSplitterHandlesCarriageReturnsAndANSI() {
        let lines = LockedArray()
        let splitter = LineSplitter { lines.append($0) }
        splitter.feed(Data("a\rb\n\u{1B}[32mgreen\u{1B}[0m\npar".utf8))
        splitter.feed(Data("tial".utf8))
        splitter.flush()
        XCTAssertEqual(lines.values, ["a", "b", "green", "partial"])
    }

    func testSplitArguments() {
        XCTAssertEqual(splitArguments(#"--a 1  --b "two words" --c '' x"#), ["--a", "1", "--b", "two words", "--c", "", "x"])
        XCTAssertEqual(splitArguments("   "), [])
    }

    func testFrameSelection() {
        XCTAssertEqual(FrameSelection.pickSharpest(scores: [1, 5, 2, 2, 9, 1], targetCount: 3), [1, 2, 4])
        XCTAssertEqual(FrameSelection.pickSharpest(scores: [1, 2], targetCount: 5), [0, 1])
        XCTAssertEqual(FrameSelection.sampleTimes(duration: 10, count: 2), [2.5, 7.5])
        let flat = [UInt8](repeating: 128, count: 16)
        XCTAssertEqual(FrameSelection.laplacianVariance(gray: flat, width: 4, height: 4), 0)
        let checker: [UInt8] = (0..<64).map { (i: Int) -> UInt8 in ((i % 8) + (i / 8)) % 2 == 0 ? 0 : 255 }
        let smooth: [UInt8] = (0..<64).map { (i: Int) -> UInt8 in UInt8((i % 8) * 30) }
        XCTAssertGreaterThan(FrameSelection.laplacianVariance(gray: checker, width: 8, height: 8),
                             FrameSelection.laplacianVariance(gray: smooth, width: 8, height: 8))
    }
}

final class LockedArray: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ s: String) { lock.lock(); storage.append(s); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

final class SplatReaderTests: XCTestCase {
    func testSplatRoundTrip() throws {
        let back = try SplatFileReader.read(data: SplatFileWriter.data(for: .sample))
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back.position(0), SIMD3(1, 2, 3))
        XCTAssertEqual(back.opacities[0], 128 / 255, accuracy: 1e-6)
        XCTAssertEqual(back.rotations[1], 1, accuracy: 1e-2)
        XCTAssertThrowsError(try SplatFileReader.read(data: Data(count: 31)))
    }
}
