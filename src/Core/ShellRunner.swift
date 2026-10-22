import Foundation

/// 统一的本地命令执行封装。app 不联网，这是唯一的外部交互面，
/// 所有调用方都应把输出当作"不可信输入"处理（解析失败要降级而不是崩溃）。
enum ShellRunner {
    static func run(_ launchPath: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        // stderr 不参与解析，直接丢弃。若接上 Pipe 又不读取，子进程写满缓冲区后同样会阻塞。
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ""
        }

        // 必须先读到 EOF，再 waitUntilExit：`ioreg -ar -k product-name` 在本机实测输出约 1.8 MB，
        // 远超管道缓冲区。若先等子进程退出，子进程会在写满管道后阻塞，父进程又在等它退出，双方死锁。
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func run(_ command: String, _ arguments: String...) -> String {
        run(command, arguments)
    }
}
