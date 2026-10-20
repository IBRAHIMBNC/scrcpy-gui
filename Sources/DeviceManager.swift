import AppKit
import Foundation

struct Device: Identifiable, Hashable {
    let serial: String
    let state: String
    let model: String

    var id: String { serial }
    var isReady: Bool { state == "device" }
    var isWireless: Bool { serial.contains(":") || serial.contains("._adb-tls-") }
    var displayName: String { model.isEmpty ? serial : model.replacingOccurrences(of: "_", with: " ") }

    var stateHint: String? {
        switch state {
        case "device": return nil
        case "unauthorized": return "Unlock the phone and accept the USB debugging prompt."
        case "offline": return "Device is offline. Reconnect the cable or restart the ADB server."
        case "no permissions": return "No permission to access this device."
        case "authorizing": return "Waiting for authorization…"
        default: return "State: \(state)"
        }
    }
}

@MainActor
final class DeviceManager: ObservableObject {
    static let shared = DeviceManager()

    @Published private(set) var devices: [Device] = []
    @Published private(set) var androidVersions: [String: String] = [:]
    @Published private(set) var running: Set<String> = []
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var adbUnavailable = false
    @Published private(set) var logText = ""
    @Published var showLog = false

    let scrcpyPath: String?
    let adbPath: String?

    private var sessions: [String: Process] = [:]
    private var recordings: [String: URL] = [:]
    private var stopping: Set<String> = []
    private var isRefreshing = false
    private var pollTimer: Timer?

    var toolProblem: String? {
        if scrcpyPath == nil { return "scrcpy not found. Expected it at ~/.local/share/scrcpy/scrcpy or in Homebrew." }
        if adbPath == nil { return "adb not found. Install Android platform-tools or keep adb next to scrcpy." }
        return nil
    }

    private init() {
        OptionKey.registerDefaults()
        let tools = Self.locateTools()
        scrcpyPath = tools.scrcpy
        adbPath = tools.adb

        guard adbPath != nil else { return }
        Task {
            await adb(["start-server"], timeout: 30)
            await refreshNow()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in await DeviceManager.shared.refreshNow() }
        }
    }

    // MARK: - Devices

    func refresh() {
        Task { await refreshNow() }
    }

    func refreshNow() async {
        guard adbPath != nil, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let result = await adb(["devices", "-l"], timeout: 10)
        if adbUnavailable == result.succeeded { adbUnavailable = !result.succeeded }
        guard result.succeeded else { return }

        let parsed = Self.parseDevices(result.output)
        if parsed != devices { devices = parsed }

        for device in parsed where device.isReady && androidVersions[device.serial] == nil {
            androidVersions[device.serial] = ""
            Task {
                let version = await adb(["-s", device.serial, "shell", "getprop", "ro.build.version.release"], timeout: 5)
                androidVersions[device.serial] = version.succeeded
                    ? version.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
            }
        }
    }

    func connect(to rawAddress: String) async -> String {
        var address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return "" }
        if !address.contains(":") { address += ":5555" }

        let result = await adb(["connect", address], timeout: 15)
        let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        appendLog(message, source: "adb")
        await refreshNow()
        return message.isEmpty ? (result.succeeded ? "Done" : "Failed") : message
    }

    func disconnect(_ device: Device) {
        Task {
            let result = await adb(["disconnect", device.serial])
            appendLog(result.output, source: "adb")
            await refreshNow()
        }
    }

    /// Switches a USB-connected device to TCP/IP mode and connects to it over Wi-Fi, so the cable can be unplugged.
    func enableWireless(_ device: Device) {
        Task {
            busy.insert(device.serial)
            defer { busy.remove(device.serial) }
            let name = device.displayName

            let route = await adb(["-s", device.serial, "shell", "ip", "route"])
            var address = Self.wifiAddress(fromRoute: route.output)
            if address == nil {
                let inet = await adb(["-s", device.serial, "shell", "ip", "-f", "inet", "addr", "show", "wlan0"])
                address = Self.wifiAddress(fromInet: inet.output)
            }
            guard let address else {
                report("Couldn't find the device's Wi-Fi address. Is it on the same network as this Mac?", source: name)
                return
            }

            let tcpip = await adb(["-s", device.serial, "tcpip", "5555"])
            guard tcpip.succeeded else {
                report(tcpip.output, source: name)
                return
            }
            appendLog(tcpip.output, source: name)

            // adbd restarts in TCP mode; give it a moment before connecting.
            try? await Task.sleep(for: .seconds(2))
            let connect = await adb(["connect", "\(address):5555"], timeout: 15)
            appendLog(connect.output, source: name)
            if !connect.output.contains("connected to") { showLog = true }
            await refreshNow()
        }
    }

    func takeScreenshot(_ device: Device) {
        Task {
            busy.insert(device.serial)
            defer { busy.remove(device.serial) }

            let url = OutputFile.make(in: .picturesDirectory, name: device.displayName, extension: "png")
            let result = await adb(["-s", device.serial, "exec-out", "screencap", "-p"], stdoutTo: url, timeout: 20)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

            if result.succeeded, size > 0 {
                appendLog("Screenshot saved to \(url.path)", source: device.displayName)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                try? FileManager.default.removeItem(at: url)
                report(result.output.isEmpty ? "Screenshot failed." : result.output, source: device.displayName)
            }
        }
    }

    func restartAdb() {
        Task {
            appendLog("Restarting ADB server…", source: "adb")
            await adb(["kill-server"], timeout: 10)
            let result = await adb(["start-server"], timeout: 30)
            appendLog(result.output, source: "adb")
            androidVersions = [:]
            await refreshNow()
        }
    }

    // MARK: - Mirroring

    func mirror(_ device: Device) {
        guard let scrcpyPath, sessions[device.serial] == nil else { return }
        let serial = device.serial
        let name = device.displayName
        let (arguments, recording) = MirrorArguments.build(serial: serial, title: name)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: scrcpyPath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        if let adbPath { environment["ADB"] = adbPath }
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
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in DeviceManager.shared.appendLog(text, source: name) }
        }
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            let reason = finished.terminationReason
            Task { @MainActor in
                DeviceManager.shared.sessionEnded(serial: serial, name: name, status: status, reason: reason)
            }
        }

        do {
            try process.run()
        } catch {
            report("Couldn't launch scrcpy: \(error.localizedDescription)", source: name)
            return
        }

        sessions[serial] = process
        running.insert(serial)
        if let recording { recordings[serial] = recording }
        appendLog("$ scrcpy " + arguments.joined(separator: " "), source: name)
    }

    func stop(_ device: Device) {
        guard let process = sessions[device.serial] else { return }
        stopping.insert(device.serial)
        process.terminate()
    }

    func stopAll() {
        for (serial, process) in sessions {
            stopping.insert(serial)
            process.terminate()
        }
    }

    private func sessionEnded(serial: String, name: String, status: Int32, reason: Process.TerminationReason) {
        sessions[serial] = nil
        running.remove(serial)
        let requested = stopping.remove(serial) != nil

        if requested || (reason == .exit && status == 0) {
            appendLog("Session ended.", source: name)
        } else {
            report("scrcpy exited with code \(status).", source: name)
        }

        if let recording = recordings.removeValue(forKey: serial),
           FileManager.default.fileExists(atPath: recording.path) {
            NSWorkspace.shared.activateFileViewerSelecting([recording])
        }
    }

    // MARK: - Log

    func appendLog(_ text: String, source: String) {
        let lines = text.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else { return }
        logText += lines.map { "[\(source)] \($0)\n" }.joined()
        if logText.utf8.count > 60_000 { logText = String(logText.suffix(40_000)) }
    }

    func clearLog() {
        logText = ""
    }

    private func report(_ text: String, source: String) {
        appendLog(text, source: source)
        showLog = true
    }

    // MARK: - Helpers

    @discardableResult
    private func adb(_ arguments: [String], stdoutTo destination: URL? = nil, timeout: TimeInterval = 15) async -> Shell.Result {
        guard let adbPath else { return Shell.Result(status: -1, output: "adb not found") }
        return await Shell.run(adbPath, arguments, stdoutTo: destination, timeout: timeout)
    }

    /// Apps launched from Finder don't inherit the shell PATH, so tools are looked up in known locations.
    private nonisolated static func locateTools() -> (scrcpy: String?, adb: String?) {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let home = fileManager.homeDirectoryForCurrentUser.path

        func firstExecutable(_ paths: [String?]) -> String? {
            paths.compactMap { $0 }.first { fileManager.isExecutableFile(atPath: $0) }
        }

        let scrcpy = firstExecutable([
            environment["SCRCPY"],
            "\(home)/.local/share/scrcpy/scrcpy",
            "\(home)/.local/bin/scrcpy",
            "/opt/homebrew/bin/scrcpy",
            "/usr/local/bin/scrcpy",
        ])
        let bundledAdb = scrcpy.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .appendingPathComponent("adb").path
        }
        let adb = firstExecutable([
            environment["ADB"],
            environment["ANDROID_HOME"].map { "\($0)/platform-tools/adb" },
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            bundledAdb,
        ])
        return (scrcpy, adb)
    }

    nonisolated static func parseDevices(_ output: String) -> [Device] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard !line.hasPrefix("List of devices"), !line.hasPrefix("* ") else { return nil }

            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { return nil }

            var state = fields[1]
            if state == "no", fields.count > 2, fields[2] == "permissions" { state = "no permissions" }
            let model = fields.dropFirst(2)
                .first { $0.hasPrefix("model:") }
                .map { String($0.dropFirst("model:".count)) } ?? ""
            return Device(serial: fields[0], state: state, model: model)
        }
    }

    /// Parses `ip route`, e.g. `192.168.1.0/24 dev wlan0 proto kernel scope link src 192.168.1.23`.
    nonisolated static func wifiAddress(fromRoute output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) where line.contains("wlan") {
            let tokens = line.split(separator: " ")
            if let index = tokens.firstIndex(of: "src"), index + 1 < tokens.count {
                return String(tokens[index + 1])
            }
        }
        return nil
    }

    /// Parses `ip -f inet addr show wlan0`, e.g. `inet 192.168.1.23/24 brd 192.168.1.255 scope global wlan0`.
    nonisolated static func wifiAddress(fromInet output: String) -> String? {
        let tokens = output.split(whereSeparator: { $0 == " " || $0.isNewline })
        guard let index = tokens.firstIndex(of: "inet"), index + 1 < tokens.count else { return nil }
        return tokens[index + 1].split(separator: "/").first.map(String.init)
    }
}
