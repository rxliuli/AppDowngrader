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
    enum ShellError: LocalizedError {
        case notBundled(String)

        var errorDescription: String? {
            switch self {
            case .notBundled(let command):
                return "\(command) is missing from the app bundle "
                    + "(Contents/Resources/bin), so there is nothing to run. "
                    + "Developers: run `bash scripts/fetch-bin.sh` before building. "
                    + "Everyone else: reinstall AppDowngrader - it ships its own copy."
            }
        }
    }

    /// Where a bundled tool lives inside the app.
    ///
    /// There is deliberately **no** PATH fallback. Running whatever `ipatool` happened to be
    /// installed looked identical to working code, and a stale Homebrew ipatool (2.3.0 at the
    /// time of writing) reads the same keychain entry, so the UI could say "logged in" while
    /// every request went out over an older protocol - and its errors look nothing like the
    /// bundled one's. A missing binary now means a broken bundle, not "use something else".
    private static func bundledURL(_ command: String) -> URL? {
        resourceBundle.url(forResource: command, withExtension: nil, subdirectory: "bin")
    }

    /// Environment for the child process. The PATH entries below are inherited by whatever the
    /// tool spawns - they are *not* a lookup path for the tool itself (see `bundledURL(_:)`).
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
        onStdout: (@Sendable (String) -> Void)? = nil,
        quiet: Bool = false
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            guard let executable = bundledURL(command) else {
                continuation.resume(throwing: ShellError.notBundled(command))
                return
            }

            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = executable
            process.arguments = arguments
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

                if !quiet {
                    Logger.shared.shellDone(
                        command,
                        arguments: process.arguments ?? arguments,
                        stdout: stdout,
                        stderr: stderr,
                        exitCode: proc.terminationStatus
                    )
                }

                resumeOnce(with: .success(ShellResult(
                    stdout: stdout, stderr: stderr, exitCode: proc.terminationStatus
                )))
            }

            do {
                if !quiet {
                    Logger.shared.shellStart(command, arguments: process.arguments ?? arguments)
                }
                try process.run()
            } catch {
                timeoutWork.cancel()
                if !quiet {
                    Logger.shared.error("failed to run \(command): \(error.localizedDescription)")
                }
                resumeOnce(with: .failure(error))
            }
        }
    }

    static func run(
        _ command: String,
        arguments: [String] = [],
        timeout: TimeInterval = 15,
        quiet: Bool = false
    ) async throws -> ShellResult {
        try await execute(command, arguments: arguments, timeout: timeout, quiet: quiet)
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

    /// Only ever answers for the bundled copy - see `bundledURL(_:)` for why there is no
    /// PATH probe here either.
    static func which(_ command: String) async -> Bool {
        bundledURL(command) != nil
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
