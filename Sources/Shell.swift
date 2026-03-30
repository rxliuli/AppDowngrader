import Foundation

/// Resource bundle that works for SwiftPM (Bundle.module), Xcode (Bundle.main),
/// and script-packaged .app bundles (Contents/Resources/).
let resourceBundle: Bundle = {
    // Check Contents/Resources/ first (script-packaged .app)
    if let resourceURL = Bundle.main.resourceURL,
       let bundle = Bundle(url: resourceURL.appendingPathComponent("AppDowngrader_AppDowngrader.bundle")) {
        return bundle
    }
    #if SWIFT_PACKAGE
    return Bundle.module
    #else
    return Bundle.main
    #endif
}()

struct ShellResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    var succeeded: Bool { exitCode == 0 }
}

enum Shell {
    /// Resolve a command to a full path: bundled binary > PATH lookup.
    private static func resolveCommand(_ command: String) -> (url: URL, isBundled: Bool) {
        // Check for bundled binary in app resources
        if let bundledURL = resourceBundle.url(forResource: command, withExtension: nil, subdirectory: "bin") {
            return (bundledURL, true)
        }
        // Fallback: use /usr/bin/env to find on PATH
        return (URL(fileURLWithPath: "/usr/bin/env"), false)
    }

    private static func makeEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? "/Users/\(NSUserName())"
        let extraPaths = [
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.npm-global/bin", "/opt/homebrew/lib/node_modules/.bin",
        ]
        let currentPath = env["PATH"] ?? "/usr/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        return env
    }

    /// Shared implementation for both run and runWithProgress.
    private static func execute(
        _ command: String,
        arguments: [String],
        timeout: TimeInterval,
        onStdout: (@Sendable (String) -> Void)? = nil
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            let resolved = resolveCommand(command)
            process.executableURL = resolved.url
            process.arguments = resolved.isBundled ? arguments : [command] + arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.environment = makeEnv()

            let lock = NSLock()
            var hasResumed = false
            let dataLock = NSLock()
            var stdoutData = Data()
            var stderrData = Data()

            func resumeOnce(with result: Result<ShellResult, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(with: result)
            }

            // Drain pipes incrementally to avoid buffer deadlock
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                dataLock.lock()
                stdoutData.append(data)
                dataLock.unlock()
                if let callback = onStdout, let str = String(data: data, encoding: .utf8) {
                    callback(str)
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                dataLock.lock()
                stderrData.append(data)
                dataLock.unlock()
            }

            let timeoutWork = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + timeout, execute: timeoutWork
            )

            process.terminationHandler = { proc in
                timeoutWork.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                dataLock.lock()
                let stdout = (String(data: stdoutData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stderr = (String(data: stderrData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                dataLock.unlock()

                resumeOnce(with: .success(ShellResult(
                    stdout: stdout, stderr: stderr, exitCode: proc.terminationStatus
                )))
            }

            do {
                try process.run()
            } catch {
                timeoutWork.cancel()
                resumeOnce(with: .failure(error))
            }
        }
    }

    static func run(
        _ command: String,
        arguments: [String] = [],
        timeout: TimeInterval = 15
    ) async throws -> ShellResult {
        try await execute(command, arguments: arguments, timeout: timeout)
    }

    /// Run a long-running command with real-time stdout streaming.
    static func runWithProgress(
        _ command: String,
        arguments: [String] = [],
        timeout: TimeInterval = 600,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> ShellResult {
        try await execute(
            command, arguments: arguments, timeout: timeout, onStdout: onOutput
        )
    }

    static func which(_ command: String) async -> Bool {
        // Check bundled binary first
        if resourceBundle.url(forResource: command, withExtension: nil, subdirectory: "bin") != nil {
            return true
        }
        guard let result = try? await run("which", arguments: [command], timeout: 5)
        else { return false }
        return result.succeeded
    }
}

extension String {
    /// Strip ANSI escape codes from terminal output.
    var strippingANSI: String {
        replacingOccurrences(
            of: #"\x1B\[[0-9;]*[a-zA-Z]"#, with: "", options: .regularExpression
        )
    }
}
