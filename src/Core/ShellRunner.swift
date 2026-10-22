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
}
