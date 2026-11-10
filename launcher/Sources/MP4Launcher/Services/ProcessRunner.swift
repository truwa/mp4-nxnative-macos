import Foundation

/// Runs one external process, delivering stdout and stderr line by line on the main actor.
final class ProcessRunner {
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private var outBuffer = Data()
    private var errBuffer = Data()
    private let lock = NSLock()

    var onStdoutLine: (@MainActor (String) -> Void)?
    var onStderrLine: (@MainActor (String) -> Void)?
    var onExit: (@MainActor (Int32) -> Void)?

    var isRunning: Bool { process.isRunning }
    var pid: pid_t { process.processIdentifier }

    /// Signal the whole process group (the child must have made itself a group leader, see ShaderPrepController).
    func signalGroup(_ sig: Int32) {
        guard process.isRunning else { return }
        kill(-process.processIdentifier, sig)
    }

    init(executable: URL, arguments: [String], workingDirectory: URL?, environment: [String: String]?) {
        process.executableURL = executable
        process.arguments = arguments
        if let wd = workingDirectory { process.currentDirectoryURL = wd }
        if let env = environment { process.environment = env }
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
    }

    func start() throws {
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            self?.consume(h.availableData, stdout: true)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            self?.consume(h.availableData, stdout: false)
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            // Drain what is left, then close the handles.
            self.outPipe.fileHandleForReading.readabilityHandler = nil
            self.errPipe.fileHandleForReading.readabilityHandler = nil
            self.consume(self.outPipe.fileHandleForReading.readDataToEndOfFile(), stdout: true, flush: true)
            self.consume(self.errPipe.fileHandleForReading.readDataToEndOfFile(), stdout: false, flush: true)
            let code = p.terminationStatus
            Task { @MainActor in self.onExit?(code) }
        }
        try process.run()
    }

    /// SIGTERM first; SIGKILL if still alive after `grace` seconds.
    func cancel(grace: TimeInterval = 3) {
        guard process.isRunning else { return }
        process.terminate()
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    private func consume(_ data: Data, stdout: Bool, flush: Bool = false) {
        lock.lock()
        if stdout { outBuffer.append(data) } else { errBuffer.append(data) }
        var buffer = stdout ? outBuffer : errBuffer
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer = buffer[buffer.index(after: nl)...]
        }
        if flush, !buffer.isEmpty {
            lines.append(String(decoding: buffer, as: UTF8.self))
            buffer = Data()
        }
        if stdout { outBuffer = Data(buffer) } else { errBuffer = Data(buffer) }
        lock.unlock()
        guard !lines.isEmpty else { return }
        let handler = stdout ? onStdoutLine : onStderrLine
        Task { @MainActor in lines.forEach { handler?($0) } }
    }
}
