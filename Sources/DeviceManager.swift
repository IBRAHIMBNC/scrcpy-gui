import AppKit
import Foundation

enum Platform: String, Hashable {
    case android
    case ios

    var label: String { self == .ios ? "iOS" : "Android" }
}

enum PlatformFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case android = "Android"
    case ios = "iOS"

    var id: String { rawValue }

    func includes(_ device: Device) -> Bool {
        switch self {
        case .all: return true
        case .android: return device.platform == .android
        case .ios: return device.platform == .ios
        }
    }
}

struct Device: Identifiable, Hashable {
    let serial: String
    let state: String
    let model: String
    var platform: Platform = .android
    var osVersion: String = ""

    var id: String { serial }
    var isReady: Bool { state == "device" }
    var isWireless: Bool {
        platform == .android && (serial.contains(":") || serial.contains("._adb-tls-"))
    }
    var displayName: String {
        switch platform {
        case .ios: return model.isEmpty ? "iPhone" : model
        case .android: return model.isEmpty ? serial : model.replacingOccurrences(of: "_", with: " ")
        }
    }

    var stateHint: String? {
        if platform == .ios {
            return state == "device" ? nil : "Unlock the iPhone and tap Trust."
        }
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
    /// OS versions by device id: Android via `getprop`, iOS via `devicectl` when Xcode is installed.
    @Published private(set) var osVersions: [String: String] = [:]
    @Published private(set) var iosModels: [String: String] = [:]
    /// True once the optional iOS version lookup has run at least once.
    @Published private(set) var iosInfoAttempted = false
    @Published private(set) var running: Set<String> = []
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var adbUnavailable = false
    @Published private(set) var logText = ""
    @Published var showLog = false

    let scrcpyPath: String?
    let adbPath: String?

    private var sessions: [String: MirrorSession] = [:]
    private var androidDevices: [Device] = []
    private var iosDevices: [Device] = []
    private let iosDiscovery = IOSDiscovery()
    private var isRefreshing = false
    private var pollTimer: Timer?

    /// What is wrong with the Android tools, if anything (independent of whether it matters right now).
    var toolProblem: String? {
        if scrcpyPath == nil { return "scrcpy not found. Expected it at ~/.local/share/scrcpy/scrcpy or in Homebrew." }
        if adbPath == nil { return "adb not found. Install Android platform-tools or keep adb next to scrcpy." }
        return nil
    }

    /// The Android tools only matter when an Android device is listed or the Android filter is selected.
    func androidToolsMatter(filter: PlatformFilter) -> Bool {
        filter == .android || devices.contains { $0.platform == .android }
    }

    func canMirror(_ device: Device) -> Bool {
        switch device.platform {
        case .android: return device.isReady && scrcpyPath != nil
        case .ios: return device.isReady
        }
    }

    private init() {
        OptionKey.registerDefaults()
        let tools = Self.locateTools()
        scrcpyPath = tools.scrcpy
        adbPath = tools.adb

        iosDiscovery.onChange = { [weak self] in self?.iosChanged() }
        iosDiscovery.start()

        if adbPath != nil {
            Task {
                await adb(["start-server"], timeout: 30)
                await refreshNow()
            }
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
        iosDiscovery.refresh()
        guard adbPath != nil, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let result = await adb(["devices", "-l"], timeout: 10)
        if adbUnavailable == result.succeeded { adbUnavailable = !result.succeeded }
        guard result.succeeded else { return }

        let parsed = Self.parseDevices(result.output)
        if parsed != androidDevices {
            androidDevices = parsed
            rebuildDevices()
        }

        for device in parsed where device.isReady && osVersions[device.serial] == nil {
            osVersions[device.serial] = ""
            Task {
                let version = await adb(["-s", device.serial, "shell", "getprop", "ro.build.version.release"], timeout: 5)
                osVersions[device.serial] = version.succeeded
                    ? version.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
            }
        }
    }

    private func iosChanged() {
        iosDevices = iosDiscovery.devices
        for (udid, info) in iosDiscovery.info {
            for device in iosDevices where IOSDiscovery.normalize(device.serial) == udid {
                if !info.version.isEmpty { osVersions[device.serial] = info.version }
                if !info.model.isEmpty { iosModels[device.serial] = info.model }
            }
        }
        if iosInfoAttempted != iosDiscovery.enrichmentAttempted { iosInfoAttempted = iosDiscovery.enrichmentAttempted }
        rebuildDevices()
    }

    /// Merges the Android and iOS lists (Android first) and attaches known OS versions.
    private func rebuildDevices() {
        let merged = (androidDevices + iosDevices).map { device -> Device in
            var copy = device
            copy.osVersion = osVersions[device.serial] ?? ""
            return copy
        }
        if merged != devices { devices = merged }
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
        if device.platform == .ios {
            takeIOSScreenshot(device)
            return
        }
        Task {
            busy.insert(device.serial)
            defer { busy.remove(device.serial) }

            let url = OutputFile.make(name: device.displayName, extension: "png")
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

    private func takeIOSScreenshot(_ device: Device) {
        let serial = device.serial
        let name = device.displayName
        if let session = sessions[serial] as? IOSMirrorSession {
            session.takeScreenshot()
            return
        }
        Task {
            busy.insert(serial)
            defer { busy.remove(serial) }
            guard await IOSMirrorSession.authorize() else {
                report(Self.cameraDeniedMessage, source: name)
                return
            }
            if let url = await IOSTemporaryCapture.screenshot(deviceID: serial, name: name) {
                appendLog("Screenshot saved to \(url.path)", source: name)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                report("Screenshot failed. Is the iPhone unlocked?", source: name)
            }
        }
    }

    private static let cameraDeniedMessage =
        "Camera access is needed to see the iPhone screen. Allow it in System Settings > Privacy & Security > Camera."

    func restartAdb() {
        Task {
            appendLog("Restarting ADB server…", source: "adb")
            await adb(["kill-server"], timeout: 10)
            let result = await adb(["start-server"], timeout: 30)
            appendLog(result.output, source: "adb")
            osVersions = osVersions.filter { key, _ in iosDevices.contains { $0.serial == key } }
            await refreshNow()
        }
    }

    // MARK: - Mirroring

    func mirror(_ device: Device) {
        guard sessions[device.serial] == nil, !busy.contains(device.serial) else { return }
        switch device.platform {
        case .android: mirrorAndroid(device)
        case .ios: mirrorIOS(device)
        }
    }

    private func mirrorAndroid(_ device: Device) {
        guard let scrcpyPath else { return }
        let serial = device.serial
        let name = device.displayName
        let (arguments, recording) = MirrorArguments.build(serial: serial, title: name)

        let session = ScrcpySession(
            scrcpyPath: scrcpyPath,
            adbPath: adbPath,
            arguments: arguments,
            recording: recording
        ) { text in
            Task { @MainActor in DeviceManager.shared.appendLog(text, source: name) }
        }
        register(session, serial: serial, name: name)
        do {
            try session.start()
        } catch {
            unregister(serial)
            report("Couldn't launch scrcpy: \(error.localizedDescription)", source: name)
            return
        }
        appendLog("$ scrcpy " + arguments.joined(separator: " "), source: name)
    }

    private func mirrorIOS(_ device: Device) {
        let serial = device.serial
        let name = device.displayName
        Task {
            busy.insert(serial)
            defer { busy.remove(serial) }
            guard await IOSMirrorSession.authorize() else {
                report(Self.cameraDeniedMessage, source: name)
                return
            }
            guard sessions[serial] == nil else { return }
            do {
                let session = try IOSMirrorSession(deviceID: serial, name: name) { text in
                    DeviceManager.shared.appendLog(text, source: name)
                }
                register(session, serial: serial, name: name)
                session.start()
                appendLog("Started iOS mirror.", source: name)
            } catch {
                report("Couldn't start the iPhone mirror: \(error.localizedDescription)", source: name)
            }
        }
    }

    private func register(_ session: MirrorSession, serial: String, name: String) {
        session.onEnd = { [weak self] end in
            self?.sessionEnded(serial: serial, name: name, end: end)
        }
        sessions[serial] = session
        running.insert(serial)
    }

    private func unregister(_ serial: String) {
        sessions[serial] = nil
        running.remove(serial)
    }

    func stop(_ device: Device) {
        sessions[device.serial]?.stop()
    }

    func stopAll() {
        for session in Array(sessions.values) { session.stop() }
    }

    private func sessionEnded(serial: String, name: String, end: SessionEnd) {
        unregister(serial)
        if let failure = end.failure {
            report(failure, source: name)
        } else {
            appendLog("Session ended.", source: name)
        }
        if let url = end.revealURL, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
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
