import Foundation

/// Local process runner. App is offline; this is the only external I/O surface.
/// Treat stdout as untrusted — degrade on parse failure, don't crash.
enum ShellRunner {
    static func run(_ launchPath: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        // Drop stderr. Attaching a Pipe and never reading it can still deadlock the child.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ""
        }

        // Read to EOF before waitUntilExit — large output (e.g. ioreg ~1.8 MB) fills the pipe
        // and deadlocks if we wait on the child first.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func run(_ command: String, _ arguments: String...) -> String {
        run(command, arguments)
    }

    /// Result of an admin-elevated shell via osascript.
    struct PrivilegedResult: Sendable {
        var output: String
        /// User cancelled the auth dialog, or osascript failed before running.
        var cancelledOrFailed: Bool
    }

    /// Prompt for an administrator password, then run a single shell command.
    /// Prefer calling this only from an explicit user action — not every automatic scan.
    static func runPrivilegedShell(_ command: String) -> PrivilegedResult {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return PrivilegedResult(output: "", cancelledOrFailed: true)
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            // Cancel / auth failure typically lands here with empty or User canceled text.
            let combined = (out + "\n" + err).trimmingCharacters(in: .whitespacesAndNewlines)
            return PrivilegedResult(output: combined, cancelledOrFailed: true)
        }
        return PrivilegedResult(output: out, cancelledOrFailed: false)
    }
}
