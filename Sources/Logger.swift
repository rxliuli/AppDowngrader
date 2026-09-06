import AppKit
import Foundation

/// Persistent, thread-safe logger that writes to
/// `~/Library/Logs/AppDowngrader/app.log` with size-based rotation.
///
/// Secrets (passwords / auth codes) passed as CLI arguments are redacted
/// before they reach the log.
final class Logger {
    static let shared = Logger()

    private let queue = DispatchQueue(label: "AppDowngrader.logger")
    private let logDir: String
    private let logFile: String
    private let maxBytes = 1_000_000   // rotate after ~1 MB
    private let maxOldFiles = 3

    private init() {
        let base = FileManager.default.urls(
            for: .libraryDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Logs", isDirectory: true)
        logDir = base.appendingPathComponent("AppDowngrader", isDirectory: true).path
        logFile = (logDir as NSString).appendingPathComponent("app.log")
        try? FileManager.default.createDirectory(
            atPath: logDir, withIntermediateDirectories: true
        )
        log("----", "AppDowngrader session started")
        log("----", "Log file: \(logFile)")
        log("----", "macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · App v\(Self.appVersion())")
    }

    // MARK: - Public API

    func info(_ message: @autoclosure () -> String) { log("INFO", message()) }
    func warn(_ message: @autoclosure () -> String) { log("WARN", message()) }
    func error(_ message: @autoclosure () -> String) { log("ERROR", message()) }

    /// Log the start of a shell invocation (redacted).
    func shellStart(_ command: String, arguments: [String]) {
        let redacted = Self.redact([command] + arguments).joined(separator: " ")
        log("SHELL", "> \(redacted)")
    }

    /// Log the result of a shell invocation.
    func shellDone(
        _ command: String,
        arguments: [String],
        stdout: String,
        stderr: String,
        exitCode: Int32
    ) {
        let redacted = Self.redact([command] + arguments).joined(separator: " ")
        log("SHELL", "< \(redacted)")
        log("SHELL", "  exit=\(exitCode)")
        if !stdout.isEmpty { log("SHELL", "  stdout: \(Self.truncate(stdout))") }
        if !stderr.isEmpty { log("SHELL", "  stderr: \(Self.truncate(stderr))") }
    }

    /// Path of the current log file.
    var logFilePath: String { logFile }
    var logDirPath: String { logDir }

    /// Reveal the log folder in Finder.
    func revealInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logDir)
    }

    // MARK: - Helpers

    /// Redact secret values (passwords, auth codes) from a CLI arg list.
    static func redact(_ args: [String]) -> [String] {
        let secretFlags: Set<String> = ["-p", "--password", "--auth-code"]
        var out: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if secretFlags.contains(a), i + 1 < args.count {
                out.append(a)
                out.append("*****")
                i += 2
                continue
            }
            out.append(a)
            i += 1
        }
        return out
    }

    private static func truncate(_ s: String, limit: Int = 4000) -> String {
        guard s.count > limit else { return s }
        return String(s.suffix(limit)) + "\n… (truncated, total \(s.count) chars)"
    }

    private static func appVersion() -> String {
        (
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String
        ) ?? "dev"
    }

    // MARK: - Internals

    private func log(_ level: String, _ message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let ts = Self.isoNow()
            let lines = message.components(separatedBy: .newlines)
            var out = ""
            // Indent continuation lines to visually group the entry.
            let indent = String(repeating: " ", count: 24)
            for (i, line) in lines.enumerated() {
                out += (i == 0 ? "\(ts) [\(level)] " : indent) + line + "\n"
            }
            self.append(out)
        }
    }

    private func append(_ text: String) {
        rotateIfNeeded()
        let url = URL(fileURLWithPath: logFile)
        if !FileManager.default.fileExists(atPath: logFile) {
            FileManager.default.createFile(atPath: logFile, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { _ = try? handle.close() }
        _ = try? handle.seekToEnd()
        _ = try? handle.write(contentsOf: Data(text.utf8))
    }

    private func rotateIfNeeded() {
        let size =
            (try? FileManager.default.attributesOfItem(atPath: logFile)[.size]
                as? NSNumber)?.intValue ?? 0
        guard size > maxBytes else { return }

        let fm = FileManager.default
        let base = (logFile as NSString).deletingPathExtension
        let ext = (logFile as NSString).pathExtension

        for i in stride(from: maxOldFiles - 1, through: 1, by: -1) {
            let src = "\(base).\(i).\(ext)"
            let dst = "\(base).\(i + 1).\(ext)"
            if fm.fileExists(atPath: dst) { try? fm.removeItem(atPath: dst) }
            if fm.fileExists(atPath: src) { try? fm.moveItem(atPath: src, toPath: dst) }
        }

        let first = "\(base).1.\(ext)"
        if fm.fileExists(atPath: first) { try? fm.removeItem(atPath: first) }
        try? fm.moveItem(atPath: logFile, toPath: first)
        fm.createFile(atPath: logFile, contents: nil)
    }

    private static func isoNow() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = .current
        return f.string(from: Date())
    }
}
