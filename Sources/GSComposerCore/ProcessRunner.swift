import Foundation

public enum OutputStream: String, Sendable { case stdout, stderr }

public struct ProcessFailure: Error, LocalizedError, Equatable {
    public var command: String
    public var exitCode: Int32
    public var lastLines: [String]

    public var errorDescription: String? {
        let tail = lastLines.suffix(8).joined(separator: "\n")
        return "コマンドが終了コード \(exitCode) で失敗しました:\n\(command)\n\(tail)"
    }
}

/// Runs an external tool, streaming its output line by line.
/// `\r`-terminated progress-bar updates are delivered as separate lines.
public final class ProcessRunner: @unchecked Sendable {
    public var environment: [String: String]

    public init(path: String? = nil) {
        var env = ProcessInfo.processInfo.environment
        if let path { env["PATH"] = path }
        // Tools print prettier (and parseable) logs without ANSI colours.
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        environment = env
    }

    @discardableResult
    public func run(_ command: ToolCommand, onLine: @escaping @Sendable (String, OutputStream) -> Void) async throws -> Int32 {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = environment
        if let cwd = command.workingDirectory {
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            process.currentDirectoryURL = cwd
        }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let tail = LineTail()
        let outSplitter = LineSplitter { line in tail.append(line); onLine(line, .stdout) }
        let errSplitter = LineSplitter { line in tail.append(line); onLine(line, .stderr) }
        outPipe.fileHandleForReading.readabilityHandler = { h in outSplitter.feed(h.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { h in errSplitter.feed(h.availableData) }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    outSplitter.feed(outPipe.fileHandleForReading.readDataToEndOfFile())
                    errSplitter.feed(errPipe.fileHandleForReading.readDataToEndOfFile())
                    outSplitter.flush()
                    errSplitter.flush()
                    cont.resume(returning: p.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                // COLMAP handles SIGINT cooperatively; escalate if the tool ignores it.
                process.interrupt()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning { process.terminate() }
                }
            }
        }
        try Task.checkCancellation()
        if status != 0 {
            throw ProcessFailure(command: command.displayString, exitCode: status, lastLines: tail.lines)
        }
        return status
    }

    /// Runs a command and returns its combined output (used for `-h` probing). Never throws on non-zero exit.
    public func capture(_ command: ToolCommand) async -> String {
        let buffer = LineTail(limit: 5_000)
        _ = try? await run(command) { line, _ in buffer.append(line) }
        return buffer.lines.joined(separator: "\n")
    }
}

final class LineTail: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private let limit: Int

    init(limit: Int = 40) { self.limit = limit }

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(line)
        if storage.count > limit { storage.removeFirst(storage.count - limit) }
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// Accumulates bytes and emits complete lines split on `\n` or `\r`.
public final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let emit: (String) -> Void

    public init(emit: @escaping (String) -> Void) { self.emit = emit }

    public func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if !lineData.isEmpty { lines.append(Self.decode(lineData)) }
        }
        lock.unlock()
        lines.forEach(emit)
    }

    public func flush() {
        lock.lock()
        let rest = buffer
        buffer.removeAll()
        lock.unlock()
        if !rest.isEmpty { emit(Self.decode(rest)) }
    }

    static func decode(_ data: Data) -> String {
        let s = String(decoding: data, as: UTF8.self)
        return stripANSI(s).trimmingCharacters(in: .whitespaces)
    }

    static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        var out = ""
        var it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            if c == "\u{1B}" {
                guard let next = it.next() else { break }
                if next == "[" {
                    while let t = it.next() { if (0x40...0x7E).contains(t.value) { break } }
                }
                continue
            }
            out.unicodeScalars.append(c)
        }
        return out
    }
}
