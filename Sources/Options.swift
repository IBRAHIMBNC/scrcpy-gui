import Foundation

/// UserDefaults keys for mirroring options. `OptionsView` binds to them with `@AppStorage`;
/// `MirrorArguments` reads them when a session starts.
enum OptionKey {
    static let maxSize = "maxSize"
    static let bitRate = "videoBitRateMbps"
    static let maxFps = "maxFps"
    static let audio = "forwardAudio"
    static let control = "controlDevice"
    static let turnScreenOff = "turnScreenOff"
    static let stayAwake = "stayAwake"
    static let showTouches = "showTouches"
    static let alwaysOnTop = "alwaysOnTop"
    static let fullscreen = "fullscreen"
    static let borderless = "borderless"
    static let record = "recordSession"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            maxSize: 0,
            bitRate: 8,
            maxFps: 0,
            audio: true,
            control: true,
            turnScreenOff: false,
            stayAwake: false,
            showTouches: false,
            alwaysOnTop: false,
            fullscreen: false,
            borderless: false,
            record: false,
        ])
    }
}

enum MirrorArguments {
    /// Builds the scrcpy argument list from the saved options. Also returns the recording path when recording is on.
    static func build(
        serial: String,
        title: String,
        defaults: UserDefaults = .standard
    ) -> (arguments: [String], recording: URL?) {
        var args = ["--serial", serial, "--window-title", title]

        let maxSize = defaults.integer(forKey: OptionKey.maxSize)
        if maxSize > 0 { args += ["--max-size", String(maxSize)] }
        let bitRate = defaults.integer(forKey: OptionKey.bitRate)
        if bitRate > 0 { args += ["--video-bit-rate", "\(bitRate)M"] }
        let maxFps = defaults.integer(forKey: OptionKey.maxFps)
        if maxFps > 0 { args += ["--max-fps", String(maxFps)] }

        if !defaults.bool(forKey: OptionKey.audio) { args.append("--no-audio") }

        // These three all act on the device through the control channel.
        if defaults.bool(forKey: OptionKey.control) {
            if defaults.bool(forKey: OptionKey.turnScreenOff) { args.append("--turn-screen-off") }
            if defaults.bool(forKey: OptionKey.stayAwake) { args.append("--stay-awake") }
            if defaults.bool(forKey: OptionKey.showTouches) { args.append("--show-touches") }
        } else {
            args.append("--no-control")
        }

        if defaults.bool(forKey: OptionKey.alwaysOnTop) { args.append("--always-on-top") }
        if defaults.bool(forKey: OptionKey.fullscreen) { args.append("--fullscreen") }
        if defaults.bool(forKey: OptionKey.borderless) { args.append("--window-borderless") }

        var recording: URL?
        if defaults.bool(forKey: OptionKey.record) {
            let url = OutputFile.make(name: title, extension: "mp4")
            args += ["--record", url.path]
            recording = url
        }
        return (args, recording)
    }
}

enum OutputFile {
    /// The single place that decides where every screenshot and recording is saved: the user's Desktop.
    static var directory: URL {
        let fileManager = FileManager.default
        return fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// A timestamped file directly on the Desktop.
    static func make(name: String, extension ext: String) -> URL {
        let base = directory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let safeName = name.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
        return base.appendingPathComponent("\(safeName) \(formatter.string(from: Date())).\(ext)")
    }
}
