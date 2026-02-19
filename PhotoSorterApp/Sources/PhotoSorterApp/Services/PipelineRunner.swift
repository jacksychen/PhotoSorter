import Foundation

/// Errors specific to the pipeline runner.
enum PipelineRunnerError: LocalizedError {
    case pythonNotFound
    case processLaunchFailed(String)
    case decodingFailed(String)
    case pipelineError(String)

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "Could not locate a Python executable. Ensure a .venv exists at the project root or python3 is in PATH."
        case .processLaunchFailed(let reason):
            return "Failed to launch pipeline process: \(reason)"
        case .decodingFailed(let detail):
            return "Failed to decode pipeline output: \(detail)"
        case .pipelineError(let message):
            return "Pipeline error: \(message)"
        }
    }
}

/// Manages the Python subprocess that runs the photo-sorting pipeline
/// and parses its JSON-line output into `PipelineMessage` values.
final class PipelineRunner: Sendable {

    // MARK: - Project root

    /// The Python project root (parent of PhotoSorterApp) where
    /// `python -m photosorter.cli_json` should be executed.
    private var projectRoot: URL {
        // In development the Swift package lives at <projectRoot>/PhotoSorterApp.
        // Walk up from the built product or from the package source to find it.
        //
        // Strategy: start from the main bundle or #file and look for the
        // `photosorter` Python package directory as a landmark.
        if let bundleURL = Bundle.main.resourceURL {
            // Walk up from the bundle location looking for the Python project
            var candidate = bundleURL
            for _ in 0..<10 {
                candidate = candidate.deletingLastPathComponent()
                let marker = candidate.appendingPathComponent("photosorter").appendingPathComponent("__init__.py")
                if FileManager.default.fileExists(atPath: marker.path) {
                    return candidate
                }
            }
        }

        // Fallback: Use the compile-time file path to derive the project root.
        // <projectRoot>/PhotoSorterApp/Sources/PhotoSorterApp/Services/PipelineRunner.swift
        let sourceFile = URL(fileURLWithPath: #filePath)
        let photoSorterApp = sourceFile
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // PhotoSorterApp
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // PhotoSorterApp (package dir)
        let derived = photoSorterApp.deletingLastPathComponent()  // project root
        if FileManager.default.fileExists(
            atPath: derived.appendingPathComponent("photosorter").appendingPathComponent("__init__.py").path
        ) {
            return derived
        }

        // Last resort — assume current working directory.
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
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

    // MARK: - Check manifest

    /// Ask the Python pipeline whether a manifest already exists for `dir`.
    ///
    /// Runs: `python -m photosorter.cli_json check-manifest --input-dir <path>`
    /// and parses the single JSON-line response.
    func checkManifest(dir: URL) async throws -> (exists: Bool, path: String?) {
        guard let python = findPythonExecutable() else {
            throw PipelineRunnerError.pythonNotFound
        }

        let process = Process()
        process.executableURL = python
        process.arguments = ["-m", "photosorter.cli_json", "check-manifest", "--input-dir", dir.path]
        process.currentDirectoryURL = projectRoot

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw PipelineRunnerError.processLaunchFailed(error.localizedDescription)
        }

        // Read all of stdout.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        // Consume stderr so the pipe doesn't block.
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if !stderrData.isEmpty, let stderrText = String(data: stderrData, encoding: .utf8) {
            // Log stderr for debugging (non-fatal).
            NSLog("[PipelineRunner] check-manifest stderr: %@", stderrText)
        }

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrData, encoding: .utf8) ?? "unknown error"
            throw PipelineRunnerError.pipelineError(
                "check-manifest exited with status \(process.terminationStatus): \(stderr)"
            )
        }

        guard let line = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty
        else {
            throw PipelineRunnerError.decodingFailed("Empty response from check-manifest")
        }

        guard let jsonData = line.data(using: .utf8) else {
            throw PipelineRunnerError.decodingFailed("Could not encode response as UTF-8")
        }

        let decoder = JSONDecoder()
        let message: PipelineMessage
        do {
            message = try decoder.decode(PipelineMessage.self, from: jsonData)
        } catch {
            throw PipelineRunnerError.decodingFailed(error.localizedDescription)
        }

        if message.type == .error {
            throw PipelineRunnerError.pipelineError(message.message ?? "Unknown error from check-manifest")
        }

        return (exists: message.exists ?? false, path: message.path)
    }

    // MARK: - Run pipeline

    /// Launch the full pipeline and stream back progress messages.
    ///
    /// Builds the command:
    /// ```
    /// python -m photosorter.cli_json run \
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
            let task = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                guard let python = self.findPythonExecutable() else {
                    // Yield an error message and finish.
                    let errorMsg = PipelineRunnerError.pythonNotFound.localizedDescription
                    NSLog("[PipelineRunner] %@", errorMsg)
                    continuation.finish()
                    return
                }

                let process = Process()
                process.executableURL = python
                process.arguments = [
                    "-m", "photosorter.cli_json", "run",
                    "--input-dir", dir.path,
                    "--device", params.device.rawValue,
                    "--batch-size", String(params.batchSize),
                    "--pooling", params.pooling.rawValue,
                    "--distance-threshold", String(params.distanceThreshold),
                    "--linkage", params.linkage.rawValue,
                    "--temporal-weight", String(params.temporalWeight),
                ]
                process.currentDirectoryURL = self.projectRoot

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                // Kill the subprocess when the stream is cancelled.
                // The read loop also checks Task.isCancelled cooperatively.
                continuation.onTermination = { @Sendable _ in
                    if process.isRunning {
                        process.terminate()
                    }
                }

                // Log stderr asynchronously for debugging.
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    NSLog("[PipelineRunner] stderr: %@", text)
                }

                do {
                    try process.run()
                } catch {
                    NSLog("[PipelineRunner] Failed to launch process: %@", error.localizedDescription)
                    continuation.finish()
                    return
                }

                let decoder = JSONDecoder()
                let fileHandle = stdoutPipe.fileHandleForReading

                // Read stdout line by line.
                var buffer = Data()
                let newline = UInt8(ascii: "\n")

                while true {
                    // Check for task cancellation.
                    if Task.isCancelled {
                        if process.isRunning {
                            process.terminate()
                        }
                        break
                    }

                    let chunk = fileHandle.availableData
                    if chunk.isEmpty {
                        // EOF — process has closed stdout.
                        break
                    }

                    buffer.append(chunk)

                    // Process all complete lines in the buffer.
                    while let newlineIndex = buffer.firstIndex(of: newline) {
                        let lineData = buffer[buffer.startIndex..<newlineIndex]
                        buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                        guard !lineData.isEmpty else { continue }

                        do {
                            let message = try decoder.decode(PipelineMessage.self, from: Data(lineData))
                            continuation.yield(message)
                        } catch {
                            // Log but don't abort — some lines may not be JSON.
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
                        continuation.yield(message)
                    } catch {
                        if let text = String(data: buffer, encoding: .utf8) {
                            NSLog("[PipelineRunner] Non-JSON trailing data: %@", text)
                        }
                    }
                }

                process.waitUntilExit()

                // Clean up stderr handler.
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                NSLog("[PipelineRunner] Process exited with status %d", process.terminationStatus)
                continuation.finish()
            }

            // Cancel the detached reading task when the stream is torn down.
            // Process termination is handled by the onTermination inside the task.
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
