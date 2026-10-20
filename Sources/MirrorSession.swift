import Foundation

/// Why a mirror session ended, and what (if anything) to reveal in Finder afterwards.
struct SessionEnd {
    var failure: String?
    var revealURL: URL?
}

/// One running mirror (a scrcpy process for Android, a capture window for iOS).
@MainActor
protocol MirrorSession: AnyObject {
    /// Called once, on the main actor, when the session is over.
    var onEnd: ((SessionEnd) -> Void)? { get set }
    func stop()
}

/// Wraps the scrcpy process used for Android devices.
@MainActor
final class ScrcpySession: MirrorSession {
    var onEnd: ((SessionEnd) -> Void)?

    private let process = Process()
    private let recording: URL?
    private var stopRequested = false

    init(
        scrcpyPath: String,
        adbPath: String?,
        arguments: [String],
        recording: URL?,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.recording = recording
        process.executableURL = URL(fileURLWithPath: scrcpyPath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        if let adbPath { environment["ADB"] = adbPath }
        let nextToScrcpy = URL(fileURLWithPath: scrcpyPath).deletingLastPathComponent().appendingPathComponent("scrcpy-server").path
        let bundledServer = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/scrcpy/scrcpy-server").path
        if scrcpyPath.hasPrefix(Bundle.main.bundleURL.path), FileManager.default.fileExists(atPath: bundledServer) {
            environment["SCRCPY_SERVER_PATH"] = bundledServer
        } else if FileManager.default.fileExists(atPath: nextToScrcpy) {
            environment["SCRCPY_SERVER_PATH"] = nextToScrcpy
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            log(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let reason = finished.terminationReason
            Task { @MainActor in self?.finished(status: status, reason: reason) }
        }
    }

    func start() throws {
        try process.run()
    }

    func stop() {
        stopRequested = true
        process.terminate()
    }

    private func finished(status: Int32, reason: Process.TerminationReason) {
        let failure = (stopRequested || (reason == .exit && status == 0)) ? nil : "scrcpy exited with code \(status)."
        onEnd?(SessionEnd(failure: failure, revealURL: recording))
        onEnd = nil
    }
}
