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
    /// Why we terminated the child, when we did. A killed child reports nothing but SIGTERM,
    /// so the exit code alone cannot tell "we timed out" from "the user stopped it".
    let stopReason: StopReason?
    var succeeded: Bool { exitCode == 0 }

    enum StopReason: Equatable {
        case timeout
        case cancelled
    }
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

    /// Owns "why did we kill it" and gives a cancelled Task (or app termination) a way to
    /// reach the child. Without this, giving up only abandons the caller: ipatool keeps
    /// provisioning in the background for ~20 minutes, detached from an app that no longer
    /// listens (observed as an orphan with PPID=1).
    private final class StopBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var reason: ShellResult.StopReason?

        init() {
            Shell.registryLock.lock()
            Shell.running[ObjectIdentifier(self)] = self
            Shell.registryLock.unlock()
        }

        deinit {
            Shell.registryLock.lock()
            Shell.running.removeValue(forKey: ObjectIdentifier(self))
            Shell.registryLock.unlock()
        }

        /// Called once the Process exists; if we were already stopped, kill it immediately.
        func attach(_ process: Process) {
            lock.lock()
            self.process = process
            let stopped = reason != nil
            lock.unlock()
            if stopped, process.isRunning { process.terminate() }
        }

        func stop(_ reason: ShellResult.StopReason) {
            lock.lock()
            if self.reason == nil { self.reason = reason }
            let process = self.process
            lock.unlock()
            if let process, process.isRunning { process.terminate() }
        }

        var stopReason: ShellResult.StopReason? {
            lock.lock()
            defer { lock.unlock() }
            return reason
        }
    }

    private static let registryLock = NSLock()
    private static var running: [ObjectIdentifier: StopBox] = [:]

    /// Terminate every child this process still has running. Called when the app quits, so a
    /// login in flight cannot outlive the window that started it.
    static func stopAll() {
        registryLock.lock()
        let boxes = Array(running.values)
        registryLock.unlock()
        for box in boxes { box.stop(.cancelled) }
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
        quiet: Bool = false,
        box: StopBox
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

            box.attach(process)

            let timeoutWork = DispatchWorkItem {
                box.stop(.timeout)
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

                let stopReason = box.stopReason

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
                    stdout: stdout, stderr: stderr, exitCode: proc.terminationStatus,
                    stopReason: stopReason
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
        let box = StopBox()
        return try await withTaskCancellationHandler {
            try await execute(
                command, arguments: arguments, timeout: timeout, quiet: quiet, box: box
            )
        } onCancel: {
            box.stop(.cancelled)
        }
    }

    /// Run a long-running command with real-time stdout streaming.
    static func runWithProgress(
        _ command: String,
        arguments: [String] = [],
        timeout: TimeInterval = 600,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> ShellResult {
        let box = StopBox()
        return try await withTaskCancellationHandler {
            try await execute(
                command, arguments: arguments, timeout: timeout, onStdout: onOutput, box: box
            )
        } onCancel: {
            box.stop(.cancelled)
        }
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
