import Foundation

enum Shell {
    struct Result: Sendable {
        let status: Int32
        let output: String
        var succeeded: Bool { status == 0 }
    }

    /// Runs a command to completion off the main thread.
    ///
    /// Output is captured through temporary files instead of pipes: `adb` may fork its server daemon, which inherits
    /// the handles and would hold a pipe open long after the command itself has exited.
    static func run(
        _ executable: String,
        _ arguments: [String],
        stdoutTo destination: URL? = nil,
        timeout: TimeInterval = 15
    ) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: runBlocking(executable, arguments, stdoutTo: destination, timeout: timeout)
                )
            }
        }
    }

    private static func runBlocking(
        _ executable: String,
        _ arguments: [String],
        stdoutTo destination: URL?,
        timeout: TimeInterval
    ) -> Result {
        let fileManager = FileManager.default
        let logURL = fileManager.temporaryDirectory.appendingPathComponent("scrcpy-gui-\(UUID().uuidString).log")
        defer { try? fileManager.removeItem(at: logURL) }

        guard fileManager.createFile(atPath: logURL.path, contents: nil),
              let logHandle = try? FileHandle(forWritingTo: logURL)
        else {
            return Result(status: -1, output: "Couldn't create a temporary file.")
        }
        defer { try? logHandle.close() }

        var outputHandle = logHandle
        if let destination {
            guard fileManager.createFile(atPath: destination.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: destination)
            else {
                return Result(status: -1, output: "Couldn't write to \(destination.path).")
            }
            outputHandle = handle
        }
        defer { if outputHandle !== logHandle { try? outputHandle.close() } }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }

        let watchdog = DispatchWorkItem { [process] in
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()

        let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return Result(status: process.terminationStatus, output: output)
    }
}
