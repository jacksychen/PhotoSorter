import Foundation

/// Errors specific to the pipeline runner.
enum PipelineRunnerError: LocalizedError {
    case pythonNotFound
    case processLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "Could not locate a Python executable. Ensure a .venv exists at the project root or python3 is in PATH."
        case .processLaunchFailed(let reason):
            return "Failed to launch pipeline process: \(reason)"
        }
    }
}

private final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        let data = buffer
        lock.unlock()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Manages the Python subprocess that runs the photo-sorting pipeline
/// and parses its JSON-line output into `PipelineMessage` values.
final class PipelineRunner: Sendable {

    // MARK: - Project root

    private func isProjectRoot(_ candidate: URL) -> Bool {
        let fileManager = FileManager.default
        let coreMarker = candidate
            .appendingPathComponent("engine")
            .appendingPathComponent("photosorter_core")
            .appendingPathComponent("photosorter")
            .appendingPathComponent("__init__.py")
        let bridgeMarker = candidate
            .appendingPathComponent("engine")
            .appendingPathComponent("photosorter_bridge")
            .appendingPathComponent("photosorter_bridge")
            .appendingPathComponent("cli_json.py")

        return fileManager.fileExists(atPath: coreMarker.path)
            && fileManager.fileExists(atPath: bridgeMarker.path)
    }

    private func locateProjectRoot(startingAt start: URL) -> URL? {
        var candidate = start.standardizedFileURL
        for _ in 0..<12 {
            if isProjectRoot(candidate) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                break
            }
            candidate = parent
        }
        return nil
    }

    /// The Python project root where
    /// `python -m photosorter_bridge.cli_json` should be executed.
    private var projectRoot: URL {
        // Resolve from bundle location first (works for development and packaged app).
        if let bundleURL = Bundle.main.resourceURL,
           let found = locateProjectRoot(startingAt: bundleURL) {
            return found
        }

        // Fallback: derive from compile-time source file path.
        let sourceFile = URL(fileURLWithPath: #filePath)
        if let found = locateProjectRoot(startingAt: sourceFile.deletingLastPathComponent()) {
            return found
        }

        // Last resort: inspect current working directory and its parents.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if let found = locateProjectRoot(startingAt: cwd) {
            return found
        }

        return cwd
    }

    private func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let bridgePath = projectRoot
            .appendingPathComponent("engine")
            .appendingPathComponent("photosorter_bridge")
            .path
        let corePath = projectRoot
            .appendingPathComponent("engine")
            .appendingPathComponent("photosorter_core")
            .path
        let injectedPythonPath = "\(bridgePath):\(corePath)"
        if let existing = env["PYTHONPATH"], !existing.isEmpty {
            env["PYTHONPATH"] = "\(injectedPythonPath):\(existing)"
        } else {
            env["PYTHONPATH"] = injectedPythonPath
        }
        return env
    }

    // MARK: - Python executable discovery

    /// Locate a usable Python executable.
    ///
    /// - In **release** builds, looks for `photosorter-cli` bundled in the app resources.
    /// - In **development**, checks for `.venv/bin/python` at the project root,
    ///   then falls back to `/usr/bin/python3` and finally `python3` via PATH.
    func findPythonExecutable() -> URL? {
        #if !DEBUG
        // Release: prefer a bundled CLI tool.
        if let resourceURL = Bundle.main.resourceURL {
            let bundledCLI = resourceURL.appendingPathComponent("photosorter-cli")
            if FileManager.default.isExecutableFile(atPath: bundledCLI.path) {
                return bundledCLI
            }
        }
        #endif

        // Development: virtual-env Python at the project root.
        let venvPython = projectRoot
            .appendingPathComponent(".venv")
            .appendingPathComponent("bin")
            .appendingPathComponent("python")
        if FileManager.default.isExecutableFile(atPath: venvPython.path) {
            return venvPython
        }

        // System Python.
        let systemPython = URL(fileURLWithPath: "/usr/bin/python3")
        if FileManager.default.isExecutableFile(atPath: systemPython.path) {
            return systemPython
        }

        // Search PATH for python3.
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            let dirs = pathEnv.split(separator: ":").map(String.init)
            for dir in dirs {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent("python3")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        return nil
    }

    // MARK: - Run pipeline

    /// Launch the full pipeline and stream back progress messages.
    ///
    /// Builds the command:
    /// ```
    /// python -m photosorter_bridge.cli_json run \
    ///   --input-dir <path> --device <val> --batch-size <val> \
    ///   --pooling <val> --distance-threshold <val> --linkage <val> \
    ///   --temporal-weight <val>
    /// ```
    ///
    /// Each line of stdout is decoded as a `PipelineMessage` and yielded
    /// through the returned `AsyncStream`. Cancelling the consuming task
    /// terminates the subprocess.
    func run(dir: URL, params: PipelineParameters) -> AsyncStream<PipelineMessage> {
        AsyncStream { continuation in
            guard let python = findPythonExecutable() else {
                let message = PipelineRunnerError.pythonNotFound.localizedDescription
                continuation.yield(PipelineMessage(type: .error, message: message))
                continuation.finish()
                return
            }

            let process = Process()
            process.executableURL = python
            process.arguments = [
                "-m", "photosorter_bridge.cli_json", "run",
                "--input-dir", dir.path,
                "--device", params.device.rawValue,
                "--batch-size", String(params.batchSize),
                "--pooling", params.pooling.rawValue,
                "--distance-threshold", String(params.distanceThreshold),
                "--linkage", params.linkage.rawValue,
                "--temporal-weight", String(params.temporalWeight),
            ]
            process.currentDirectoryURL = projectRoot
            process.environment = processEnvironment()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stderrCollector = StderrCollector()
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stderrCollector.append(data)
                if let text = String(data: data, encoding: .utf8) {
                    NSLog("[PipelineRunner] stderr: %@", text)
                }
            }

            do {
                try process.run()
            } catch {
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let message = PipelineRunnerError.processLaunchFailed(error.localizedDescription)
                    .errorDescription ?? error.localizedDescription
                continuation.yield(
                    PipelineMessage(
                        type: .error,
                        message: message
                    )
                )
                continuation.finish()
                return
            }

            let readerTask = Task.detached(priority: .userInitiated) {
                let decoder = JSONDecoder()
                let fileHandle = stdoutPipe.fileHandleForReading
                var sawErrorMessage = false

                // Read stdout line by line.
                var buffer = Data()
                let newline = UInt8(ascii: "\n")

                while true {
                    if Task.isCancelled {
                        break
                    }

                    let chunk = fileHandle.availableData
                    if chunk.isEmpty {
                        break
                    }

                    buffer.append(chunk)

                    while let newlineIndex = buffer.firstIndex(of: newline) {
                        let lineData = buffer[buffer.startIndex..<newlineIndex]
                        buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                        guard !lineData.isEmpty else { continue }

                        do {
                            let message = try decoder.decode(PipelineMessage.self, from: Data(lineData))
                            if message.type == .error {
                                sawErrorMessage = true
                            }
                            continuation.yield(message)
                        } catch {
                            if let text = String(data: Data(lineData), encoding: .utf8) {
                                NSLog("[PipelineRunner] Non-JSON stdout line: %@", text)
                            }
                        }
                    }
                }

                // Process any remaining data in the buffer (line without trailing newline).
                if !buffer.isEmpty {
                    do {
                        let message = try decoder.decode(PipelineMessage.self, from: buffer)
                        if message.type == .error {
                            sawErrorMessage = true
                        }
                        continuation.yield(message)
                    } catch {
                        if let text = String(data: buffer, encoding: .utf8) {
                            NSLog("[PipelineRunner] Non-JSON trailing data: %@", text)
                        }
                    }
                }

                process.waitUntilExit()
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let status = process.terminationStatus
                NSLog("[PipelineRunner] Process exited with status %d", status)

                if !Task.isCancelled, status != 0, !sawErrorMessage {
                    let stderrText = stderrCollector.text()
                    let fallback = stderrText.isEmpty
                        ? "Pipeline exited with status \(status)."
                        : stderrText
                    continuation.yield(PipelineMessage(type: .error, message: fallback))
                }

                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                readerTask.cancel()
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}
