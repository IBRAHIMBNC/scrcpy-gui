@preconcurrency import AVFoundation
import CoreMediaIO
import Foundation

/// Finds iPhones/iPads connected over USB. They show up as "muxed" external capture devices once macOS is
/// told to allow screen-capture devices. Version/model details are an optional extra from Xcode's `devicectl`.
@MainActor
final class IOSDiscovery {
    struct Info {
        var version: String
        var model: String
    }

    private(set) var devices: [Device] = []
    /// Keyed by normalized UDID (see `normalize`).
    private(set) var info: [String: Info] = [:]
    private(set) var enrichmentAttempted = false
    var onChange: (() -> Void)?

    private var session: AVCaptureDevice.DiscoverySession?
    private var observers: [NSObjectProtocol] = []
    private var lastEnrichment = Date.distantPast
    private var isEnriching = false

    func start() {
        Self.allowScreenCaptureDevices()
        session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        )
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        guard let session else { return }
        let found = session.devices
            .filter { $0.hasMediaType(.muxed) }
            .map { Device(serial: $0.uniqueID, state: "device", model: $0.localizedName, platform: .ios) }

        let previous = Set(devices.map(\.serial))
        let appeared = found.contains { !previous.contains($0.serial) }
        if found != devices {
            devices = found
            onChange?()
        }
        if !found.isEmpty, appeared || Date().timeIntervalSince(lastEnrichment) > 10 {
            enrich()
        }
    }

    // MARK: - CoreMediaIO

    private static func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
    }

    // MARK: - Optional enrichment (Xcode)

    private func enrich() {
        guard !isEnriching else { return }
        isEnriching = true
        lastEnrichment = Date()
        Task {
            let parsed = await Self.queryDeviceCtl()
            isEnriching = false
            enrichmentAttempted = true
            if let parsed { info = parsed }
            onChange?()
        }
    }

    /// Returns nil when Xcode isn't usable. Never shows an install prompt: `xcode-select -p` is checked first.
    private nonisolated static func queryDeviceCtl() async -> [String: Info]? {
        let select = await Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 3)
        guard select.succeeded else { return nil }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-mirror-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = await Shell.run(
            "/usr/bin/xcrun",
            ["devicectl", "list", "devices", "--quiet", "--json-output", output.path],
            timeout: 20
        )
        guard result.succeeded, let data = try? Data(contentsOf: output) else { return nil }
        return parse(data)
    }

    /// Defensive: any unexpected shape just yields fewer (or no) entries.
    nonisolated static func parse(_ data: Data) -> [String: Info]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let list = result["devices"] as? [[String: Any]]
        else { return nil }

        var parsed: [String: Info] = [:]
        for entry in list {
            let hardware = entry["hardwareProperties"] as? [String: Any]
            let properties = entry["deviceProperties"] as? [String: Any]
            guard let udid = hardware?["udid"] as? String else { continue }
            let version = (properties?["osVersionNumber"] as? String) ?? ""
            let model = (hardware?["marketingName"] as? String) ?? (hardware?["productType"] as? String) ?? ""
            parsed[normalize(udid)] = Info(version: version, model: model)
        }
        return parsed
    }

    nonisolated static func normalize(_ udid: String) -> String {
        udid.replacingOccurrences(of: "-", with: "").uppercased()
    }
}
