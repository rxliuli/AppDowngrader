import Foundation

struct ShellResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    var succeeded: Bool { exitCode == 0 }
}

enum Shell {
    private static func makeEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        return env
    }

    static func run(
        _ command: String,
        arguments: [String] = [],
        timeout: TimeInterval = 15
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.environment = makeEnv()

            let lock = NSLock()
            var hasResumed = false

            func resumeOnce(with result: Result<ShellResult, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(with: result)
            }

            let timeoutWork = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + timeout, execute: timeoutWork
            )

            process.terminationHandler = { proc in
                timeoutWork.cancel()
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = (String(data: stdoutData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stderr = (String(data: stderrData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Run a long-running command with real-time stdout streaming.
    static func runWithProgress(
        _ command: String,
        arguments: [String] = [],
        timeout: TimeInterval = 600,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.environment = makeEnv()

            let lock = NSLock()
            var hasResumed = false
            let dataLock = NSLock()
            var collectedStdout = Data()
            var collectedStderr = Data()

            func resumeOnce(with result: Result<ShellResult, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(with: result)
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                dataLock.lock()
                collectedStdout.append(data)
                dataLock.unlock()
                if let str = String(data: data, encoding: .utf8) {
                    onOutput(str)
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                dataLock.lock()
                collectedStderr.append(data)
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
                let stdout = (String(data: collectedStdout, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stderr = (String(data: collectedStderr, encoding: .utf8) ?? "")
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

    static func which(_ command: String) async -> Bool {
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
