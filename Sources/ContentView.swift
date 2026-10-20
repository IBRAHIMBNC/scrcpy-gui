import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var manager: DeviceManager
    @AppStorage("showOptions") private var showOptions = true

    var body: some View {
        VStack(spacing: 0) {
            if let problem = manager.toolProblem {
                Banner(text: problem, systemImage: "exclamationmark.triangle.fill")
            } else if manager.adbUnavailable {
                Banner(text: "ADB isn't responding. Try Restart ADB Server from the toolbar menu.",
                       systemImage: "bolt.horizontal.circle")
            }
            deviceList
            Divider()
            ConnectBar()
            if manager.showLog {
                Divider()
                LogView()
            }
        }
        .navigationTitle("Scrcpy GUI")
        .navigationSubtitle(manager.devices.count == 1 ? "1 device" : "\(manager.devices.count) devices")
        .toolbar { toolbar }
        .inspector(isPresented: $showOptions) {
            OptionsView()
                .inspectorColumnWidth(min: 250, ideal: 290, max: 340)
        }
    }

    @ViewBuilder
    private var deviceList: some View {
        if manager.devices.isEmpty {
            ContentUnavailableView {
                Label("No Devices", systemImage: "smartphone")
            } description: {
                Text("Plug in an Android device with USB debugging turned on, or connect one over Wi-Fi below.")
            }
            .frame(maxHeight: .infinity)
        } else {
            List(manager.devices) { device in
                DeviceRow(device: device)
            }
            .listStyle(.inset)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { manager.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh device list (⌘R)")

            Menu {
                Button("Restart ADB Server") { manager.restartAdb() }
                Button("Stop All Sessions") { manager.stopAll() }
                    .disabled(manager.running.isEmpty)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }

            Toggle(isOn: $manager.showLog) {
                Label("Log", systemImage: "text.alignleft")
            }
            .help("Show scrcpy and adb output")

            Button { showOptions.toggle() } label: {
                Label("Options", systemImage: "sidebar.trailing")
            }
            .help("Mirroring options")
        }
    }
}

// MARK: - Device row

private struct DeviceRow: View {
    @EnvironmentObject private var manager: DeviceManager
    let device: Device

    private var isRunning: Bool { manager.running.contains(device.serial) }
    private var isBusy: Bool { manager.busy.contains(device.serial) }

    var body: some View {
        HStack(spacing: 12) {
            deviceIcon

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.displayName).font(.headline)
                    if isRunning { MirroringBadge() }
                }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let hint = device.stateHint {
                    Text(hint).font(.caption).foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 12)

            if isBusy { ProgressView().controlSize(.small) }

            Button { manager.takeScreenshot(device) } label: {
                Label("Screenshot", systemImage: "camera")
            }
            .labelStyle(.iconOnly)
            .controlSize(.large)
            .disabled(!device.isReady || isBusy)
            .help("Take screenshot (saved to ~/Pictures/scrcpy)")

            if isRunning {
                Button("Stop") { manager.stop(device) }
                    .controlSize(.large)
            } else {
                Button("Mirror") { manager.mirror(device) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!device.isReady || manager.scrcpyPath == nil)
            }

            Menu { actions } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
        .padding(.vertical, 6)
        .contextMenu { actions }
    }

    private var deviceIcon: some View {
        Image(systemName: "smartphone")
            .font(.system(size: 26, weight: .light))
            .foregroundStyle(device.isReady ? Color.primary : Color.secondary)
            .frame(width: 34, height: 40)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: device.isWireless ? "wifi" : "cable.connector")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .background(.background, in: Circle())
            }
    }

    private var details: String {
        var parts = [device.serial]
        if let version = manager.androidVersions[device.serial], !version.isEmpty {
            parts.append("Android \(version)")
        }
        parts.append(device.isWireless ? "Wi-Fi" : "USB")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actions: some View {
        Button("Take Screenshot") { manager.takeScreenshot(device) }
            .disabled(!device.isReady)
        if device.isWireless {
            Button("Disconnect") { manager.disconnect(device) }
        } else {
            Button("Enable Wi-Fi Debugging") { manager.enableWireless(device) }
                .disabled(!device.isReady || isRunning)
        }
        Divider()
        Button("Copy Serial") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(device.serial, forType: .string)
        }
    }
}

private struct MirroringBadge: View {
    var body: some View {
        Text("Mirroring")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.15), in: Capsule())
    }
}

private struct Banner: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.15))
    }
}

// MARK: - Connect over Wi-Fi

private struct ConnectBar: View {
    @EnvironmentObject private var manager: DeviceManager
    @State private var address = ""
    @State private var message: String?
    @State private var isConnecting = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi").foregroundStyle(.secondary)
            TextField("192.168.1.20:5555", text: $address)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .onSubmit(connect)
                .help("Connect to a device over Wi-Fi (adb connect)")
            Button("Connect", action: connect)
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting || manager.adbPath == nil)
            if isConnecting {
                ProgressView().controlSize(.small)
            } else if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func connect() {
        guard !isConnecting else { return }
        let target = address
        isConnecting = true
        message = nil
        Task {
            message = await manager.connect(to: target)
            isConnecting = false
        }
    }
}

// MARK: - Log

private struct LogView: View {
    @EnvironmentObject private var manager: DeviceManager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { manager.clearLog() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(manager.logText.isEmpty ? "No output yet." : manager.logText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(manager.logText.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    Color.clear.frame(height: 1).id("end")
                }
                .onAppear { proxy.scrollTo("end") }
                .onChange(of: manager.logText) { proxy.scrollTo("end") }
            }
        }
        .frame(height: 170)
        .background(.background.secondary)
    }
}

// MARK: - Options

private struct OptionsView: View {
    @AppStorage(OptionKey.maxSize) private var maxSize = 0
    @AppStorage(OptionKey.bitRate) private var bitRate = 8
    @AppStorage(OptionKey.maxFps) private var maxFps = 0
    @AppStorage(OptionKey.audio) private var audio = true
    @AppStorage(OptionKey.control) private var control = true
    @AppStorage(OptionKey.turnScreenOff) private var turnScreenOff = false
    @AppStorage(OptionKey.stayAwake) private var stayAwake = false
    @AppStorage(OptionKey.showTouches) private var showTouches = false
    @AppStorage(OptionKey.alwaysOnTop) private var alwaysOnTop = false
    @AppStorage(OptionKey.fullscreen) private var fullscreen = false
    @AppStorage(OptionKey.borderless) private var borderless = false
    @AppStorage(OptionKey.record) private var record = false

    var body: some View {
        Form {
            Section("Video") {
                Picker("Max size", selection: $maxSize) {
                    Text("Native").tag(0)
                    ForEach([1920, 1600, 1280, 1024, 800], id: \.self) { Text(verbatim: "\($0) px").tag($0) }
                }
                Picker("Bit rate", selection: $bitRate) {
                    ForEach([2, 4, 8, 16, 24], id: \.self) { Text(verbatim: "\($0) Mbps").tag($0) }
                }
                Picker("Frame rate", selection: $maxFps) {
                    Text("Unlimited").tag(0)
                    ForEach([30, 60, 120], id: \.self) { Text(verbatim: "\($0) fps").tag($0) }
                }
            }

            Section("Device") {
                Toggle("Forward audio", isOn: $audio)
                Toggle("Control with mouse & keyboard", isOn: $control)
                Toggle("Turn device screen off", isOn: $turnScreenOff).disabled(!control)
                Toggle("Keep device awake", isOn: $stayAwake).disabled(!control)
                Toggle("Show touches", isOn: $showTouches).disabled(!control)
            }

            Section("Window") {
                Toggle("Always on top", isOn: $alwaysOnTop)
                Toggle("Fullscreen", isOn: $fullscreen)
                Toggle("Borderless", isOn: $borderless)
            }

            Section {
                Toggle("Record session", isOn: $record)
            } footer: {
                Text("Recordings go to ~/Movies/scrcpy and screenshots to ~/Pictures/scrcpy. Changes apply to the next session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
