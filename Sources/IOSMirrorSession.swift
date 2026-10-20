@preconcurrency import AVFoundation
import AppKit
import CoreImage

// MARK: - Screenshot and frame grabbing

enum IOSScreenshot {
    private static let context = CIContext()

    /// The one place that turns a captured frame into a PNG in the Desktop.
    nonisolated static func save(_ buffer: CVPixelBuffer, name: String) -> URL? {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = context.createCGImage(image, from: image.extent),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else { return nil }
        let url = OutputFile.make(name: name, extension: "png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

/// Receives video frames on a capture queue. Keeps the latest frame for screenshots and reports size changes.
final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var waiting: [(CVPixelBuffer) -> Void] = []
    private var lastSize = CGSize.zero
    /// Called on the main queue when the frame size changes (including the first frame).
    var onSize: (@Sendable (CGSize) -> Void)?
    var onFirstFrame: (@Sendable () -> Void)?
    private var sawFirstFrame = false

    /// Saves the newest frame as a PNG (immediately if there is one, otherwise when one arrives).
    /// `completion` runs on a background queue with the file URL, or nil on failure.
    func saveScreenshot(name: String, completion: @escaping @Sendable (URL?) -> Void) {
        let handler: (CVPixelBuffer) -> Void = { buffer in
            nonisolated(unsafe) let frame = buffer
            DispatchQueue.global(qos: .userInitiated).async {
                completion(IOSScreenshot.save(frame, name: name))
            }
        }
        lock.lock()
        let current = latest
        if current == nil { waiting.append(handler) }
        lock.unlock()
        if let current { handler(current) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        lock.lock()
        latest = buffer
        let changed = size != lastSize
        lastSize = size
        let pending = waiting
        waiting = []
        let first = !sawFirstFrame
        sawFirstFrame = true
        lock.unlock()

        if changed || first {
            DispatchQueue.main.async { [self] in
                if changed { onSize?(size) }
                if first { onFirstFrame?() }
            }
        }
        for handler in pending { handler(buffer) }
    }
}

/// A short-lived capture used when the main window asks for a screenshot and no mirror window is open.
@MainActor
enum IOSTemporaryCapture {
    static func screenshot(deviceID: String, name: String) async -> URL? {
        guard let device = AVCaptureDevice(uniqueID: deviceID),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return nil }

        let session = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        let grabber = FrameGrabber()
        let queue = DispatchQueue(label: "devicemirror.screenshot")
        guard session.canAddInput(input), session.canAddOutput(output) else { return nil }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(grabber, queue: queue)
        queue.async { session.startRunning() }
        defer { queue.async { session.stopRunning() } }

        // Give the stream a moment so the frame we take is current, not a startup frame.
        try? await Task.sleep(for: .milliseconds(400))

        return await withCheckedContinuation { continuation in
            let gate = NSLock()
            nonisolated(unsafe) var finished = false
            @Sendable func finish(_ url: URL?) {
                gate.lock()
                let first = !finished
                finished = true
                gate.unlock()
                if first { continuation.resume(returning: url) }
            }
            grabber.saveScreenshot(name: name) { finish($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { finish(nil) }
        }
    }
}

// MARK: - Window views

/// Hosts the capture preview layer. Aspect-fit, on black.
private final class VideoView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        layer = previewLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Dark translucent bar over the top of the video: device name on the left, Screenshot and Record on the right.
private final class OverlayBar: NSVisualEffectView {
    let nameLabel = NSTextField(labelWithString: "")
    let screenshotButton = NSButton()
    let recordButton = NSButton()
    var leftInset: CGFloat = 14 { didSet { needsLayout = true } }

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)

        nameLabel.textColor = .white
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.alignment = .center
        addSubview(nameLabel)

        for button in [screenshotButton, recordButton] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .white
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            addSubview(button)
        }
        screenshotButton.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Screenshot")
        screenshotButton.toolTip = "Screenshot (⌘S)"
        setRecording(false, elapsed: "")
    }

    required init?(coder: NSCoder) { fatalError() }

    func setRecording(_ recording: Bool, elapsed: String) {
        if recording {
            recordButton.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
            recordButton.contentTintColor = .systemRed
            recordButton.imagePosition = .imageLeft
            recordButton.attributedTitle = NSAttributedString(string: " " + elapsed, attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            ])
            recordButton.toolTip = "Stop recording (⌘R)"
        } else {
            recordButton.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record")
            recordButton.contentTintColor = .white
            recordButton.imagePosition = .imageOnly
            recordButton.attributedTitle = NSAttributedString(string: "")
            recordButton.toolTip = "Start recording (⌘R)"
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let rightInset: CGFloat = 12
        var x = bounds.width - rightInset
        for button in [recordButton, screenshotButton] {
            let size = button.fittingSize
            let width = max(size.width, 24)
            x -= width
            button.frame = NSRect(x: x, y: (bounds.height - size.height) / 2, width: width, height: size.height)
            x -= 10
        }
        let labelHeight = nameLabel.intrinsicContentSize.height
        let width = max(0, min(nameLabel.intrinsicContentSize.width, x - leftInset))
        // Centered in the bar when there is room, otherwise squeezed between the traffic lights and the buttons.
        let originX = min(max((bounds.width - width) / 2, leftInset), max(leftInset, x - width))
        nameLabel.frame = NSRect(x: originX, y: (bounds.height - labelHeight) / 2, width: width, height: labelHeight)
    }
}

/// Small red-dot-and-timer badge shown while recording with the overlay hidden. Never catches clicks.
private final class RecordingBadge: NSView {
    private let label = NSTextField(labelWithString: "00:00")
    private let dot = NSView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 11
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        addSubview(dot)
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        addSubview(label)
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            needsLayout = true
        }
    }

    var preferredSize: NSSize {
        NSSize(width: 8 + 6 + label.intrinsicContentSize.width + 20, height: 22)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        dot.frame = NSRect(x: 10, y: (bounds.height - 8) / 2, width: 8, height: 8)
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 24, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
}

/// Brief "Saved" pill in the middle of the video.
private final class FlashView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "Saved")

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 14
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        addSubview(label)
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(width: size.width + 32, height: size.height + 14)
    }

    func setText(_ text: String) {
        label.stringValue = text
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
}

/// Window content: video filling everything, with the overlay, badge and flash on top.
private final class MirrorContentView: NSView {
    let video: VideoView
    let overlay = OverlayBar()
    let badge = RecordingBadge()
    let flash = FlashView()
    /// Vertical distance from the top edge to the middle of the overlay row (matches the traffic lights).
    var rowCenterFromTop: CGFloat = 18 { didSet { needsLayout = true } }
    var onActivity: (() -> Void)?
    var onExit: (() -> Void)?

    init(session: AVCaptureSession) {
        video = VideoView(session: session)
        super.init(frame: .zero)
        addSubview(video)
        addSubview(overlay)
        addSubview(badge)
        addSubview(flash)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onActivity?() }
    override func mouseMoved(with event: NSEvent) { onActivity?() }
    override func mouseExited(with event: NSEvent) { onExit?() }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        relayout()
    }

    override func layout() {
        super.layout()
        relayout()
    }

    private func relayout() {
        video.frame = bounds
        let barHeight = max(36, rowCenterFromTop * 2)
        overlay.frame = NSRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        let badgeSize = badge.preferredSize
        badge.frame = NSRect(x: bounds.width - badgeSize.width - 12, y: bounds.height - badgeSize.height - 12,
                             width: badgeSize.width, height: badgeSize.height)
        let flashSize = flash.preferredSize
        flash.frame = NSRect(x: (bounds.width - flashSize.width) / 2, y: (bounds.height - flashSize.height) / 2,
                             width: flashSize.width, height: flashSize.height)
    }
}

private final class MirrorWindow: NSWindow {
    var onShortcut: ((String) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased(), onShortcut?(key) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Session

@MainActor
final class IOSMirrorSession: NSObject, MirrorSession, NSWindowDelegate, AVCaptureFileOutputRecordingDelegate {
    /// Recordings still being finalized; the app waits for these before quitting.
    static var pendingFinalizations = 0

    var onEnd: ((SessionEnd) -> Void)?

    private let deviceID: String
    private let name: String
    private let log: (String) -> Void
    private let capture = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let frameOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioPreviewOutput()
    private let grabber = FrameGrabber()
    private let queue = DispatchQueue(label: "devicemirror.session")
    private let frameQueue = DispatchQueue(label: "devicemirror.frames")

    private let window: MirrorWindow
    private let content: MirrorContentView
    private let titled: Bool
    private let sizeLimit: CGFloat
    private var aspect: CGFloat

    private var observers: [NSObjectProtocol] = []
    private var hideTimer: Timer?
    private var flashTimer: Timer?
    private var recordTimer: Timer?
    private var overlayVisible = true
    private var isFullscreen = false
    private var isRecording = false
    private var recordingStart = Date()
    private var autoRecordPending: Bool
    private var lastRecording: URL?
    private var ended = false
    private var finalizing = false

    init(deviceID: String, name: String, log: @escaping (String) -> Void) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw NSError(domain: "DeviceMirror", code: 1, userInfo: [NSLocalizedDescriptionKey: "The iPhone is no longer connected."])
        }
        let input = try AVCaptureDeviceInput(device: device)
        self.deviceID = deviceID
        self.name = name
        self.log = log

        let defaults = UserDefaults.standard
        titled = !defaults.bool(forKey: OptionKey.borderless)
        autoRecordPending = defaults.bool(forKey: OptionKey.record)

        capture.beginConfiguration()
        guard capture.canAddInput(input) else {
            capture.commitConfiguration()
            throw NSError(domain: "DeviceMirror", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't read from the iPhone."])
        }
        capture.addInput(input)
        frameOutput.alwaysDiscardsLateVideoFrames = true
        if capture.canAddOutput(frameOutput) { capture.addOutput(frameOutput) }
        if capture.canAddOutput(movieOutput) { capture.addOutput(movieOutput) }
        if capture.canAddOutput(audioOutput) { capture.addOutput(audioOutput) }
        capture.commitConfiguration()
        audioOutput.volume = defaults.bool(forKey: OptionKey.audio) ? 1 : 0

        // Initial shape comes from the device format; the first real frame corrects it.
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        aspect = dimensions.width > 0 && dimensions.height > 0
            ? CGFloat(dimensions.width) / CGFloat(dimensions.height)
            : 9.0 / 19.5

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let maxSize = defaults.integer(forKey: OptionKey.maxSize)
        sizeLimit = maxSize > 0 ? CGFloat(maxSize) : visible.height * 0.85

        let size = Self.fit(aspect: aspect, limit: sizeLimit, in: visible)
        var style: NSWindow.StyleMask = [.resizable]
        style.formUnion(titled ? [.titled, .closable, .miniaturizable, .fullSizeContentView] : [.borderless])
        window = MirrorWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        content = MirrorContentView(session: capture)
        super.init()

        window.title = name
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.backgroundColor = .black
        window.isMovableByWindowBackground = true
        window.acceptsMouseMovedEvents = true
        window.contentAspectRatio = size
        window.delegate = self
        window.onShortcut = { [weak self] key in self?.handleShortcut(key) ?? false }
        if titled {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        } else {
            window.isOpaque = false
            window.backgroundColor = .clear
            content.wantsLayer = true
            content.layer?.cornerRadius = 12
            content.layer?.masksToBounds = true
        }
        if defaults.bool(forKey: OptionKey.alwaysOnTop) { window.level = .floating }

        content.overlay.nameLabel.stringValue = name
        content.overlay.screenshotButton.target = self
        content.overlay.screenshotButton.action = #selector(screenshotClicked)
        content.overlay.recordButton.target = self
        content.overlay.recordButton.action = #selector(recordClicked)
        content.onActivity = { [weak self] in self?.showOverlay() }
        content.onExit = { [weak self] in self?.setOverlay(false) }

        grabber.onSize = { [weak self] size in
            MainActor.assumeIsolated { self?.applyVideoSize(size) }
        }
        grabber.onFirstFrame = { [weak self] in
            MainActor.assumeIsolated { self?.firstFrameArrived() }
        }
        frameOutput.setSampleBufferDelegate(grabber, queue: frameQueue)
    }

    func start() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        updateLayoutMetrics()
        if UserDefaults.standard.bool(forKey: OptionKey.fullscreen) { window.toggleFullScreen(nil) }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.object as? AVCaptureDevice)?.uniqueID
            MainActor.assumeIsolated {
                guard let self, id == self.deviceID else { return }
                self.log("iPhone disconnected.")
                self.window.close()
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: capture, queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "Capture error."
            MainActor.assumeIsolated {
                self?.log(message)
                self?.window.close()
            }
        })
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fullscreenChanged() }
            })
        }

        let capture = capture
        queue.async { capture.startRunning() }
        showOverlay()
    }

    func stop() {
        window.close()
    }

    // MARK: Permissions

    static func authorize() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    // MARK: Window sizing

    private static func fit(aspect: CGFloat, limit: CGFloat, in visible: NSRect) -> NSSize {
        var width: CGFloat
        var height: CGFloat
        if aspect <= 1 {
            height = limit
            width = height * aspect
        } else {
            width = limit
            height = width / aspect
        }
        let scale = min(1, visible.width / width, visible.height / height)
        width *= scale
        height *= scale
        return NSSize(width: width, height: height)
    }

    private func applyVideoSize(_ size: CGSize) {
        guard !ended, size.width > 0, size.height > 0 else { return }
        aspect = size.width / size.height
        window.contentAspectRatio = size
        guard !isFullscreen else { return }

        let visible = (window.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let target = Self.fit(aspect: aspect, limit: sizeLimit, in: visible)
        let old = window.frame
        var frame = NSRect(
            x: old.midX - target.width / 2,
            y: old.midY - target.height / 2,
            width: target.width,
            height: target.height
        )
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true, animate: false)
    }

    private func firstFrameArrived() {
        guard !ended, autoRecordPending else { return }
        autoRecordPending = false
        startRecording()
    }

    private func fullscreenChanged() {
        isFullscreen = window.styleMask.contains(.fullScreen)
        updateLayoutMetrics()
        setOverlay(overlayVisible)
        showOverlay()
    }

    /// Lines the overlay row up with the traffic lights, or uses plain insets without them (fullscreen, borderless).
    private func updateLayoutMetrics() {
        if titled, !isFullscreen,
           let close = window.standardWindowButton(.closeButton),
           let zoom = window.standardWindowButton(.zoomButton),
           let container = close.superview {
            content.layoutSubtreeIfNeeded()
            let closeFrame = content.convert(close.frame, from: container)
            let zoomFrame = content.convert(zoom.frame, from: container)
            content.rowCenterFromTop = max(18, content.bounds.height - closeFrame.midY)
            content.overlay.leftInset = zoomFrame.maxX + 12
        } else {
            content.rowCenterFromTop = 18
            content.overlay.leftInset = 14
        }
    }

    private var trafficLights: [NSButton] {
        guard titled, !isFullscreen else { return [] }
        return [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
    }

    // MARK: Overlay

    private func showOverlay() {
        guard !ended else { return }
        hideTimer?.invalidate()
        if !overlayVisible { setOverlay(true) }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.setOverlay(false) }
        }
    }

    private func setOverlay(_ visible: Bool) {
        overlayVisible = visible
        if !visible { hideTimer?.invalidate() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            content.overlay.animator().alphaValue = visible ? 1 : 0
            for button in trafficLights { button.animator().alphaValue = visible ? 1 : 0 }
            content.badge.animator().alphaValue = (!visible && isRecording) ? 1 : 0
        }
    }

    private func flash(_ text: String) {
        content.flash.setText(text)
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            content.flash.animator().alphaValue = 1
        }
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    self.content.flash.animator().alphaValue = 0
                }
            }
        }
        showOverlay()
    }

    // MARK: Shortcuts and buttons

    private func handleShortcut(_ key: String) -> Bool {
        switch key {
        case "s": takeScreenshot()
        case "r": toggleRecording()
        default: return false
        }
        return true
    }

    @objc private func screenshotClicked() { takeScreenshot() }
    @objc private func recordClicked() { toggleRecording() }

    // MARK: Screenshot

    func takeScreenshot() {
        let name = name
        grabber.saveScreenshot(name: name) { [weak self] url in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let url {
                        self.log("Screenshot saved to \(url.path)")
                        self.flash("Saved")
                    } else {
                        self.log("Screenshot failed.")
                        self.flash("Failed")
                    }
                }
            }
        }
    }

    // MARK: Recording

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        guard !ended, !isRecording, !movieOutput.isRecording else { return }
        let url = OutputFile.make(name: name, extension: "mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        recordingStart = Date()
        log("Recording to \(url.path)")
        updateRecordingUI()
        recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRecordingUI() }
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordTimer?.invalidate()
        updateRecordingUI()
        if movieOutput.isRecording { movieOutput.stopRecording() }
    }

    private func updateRecordingUI() {
        let seconds = Int(Date().timeIntervalSince(recordingStart))
        let text = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        content.overlay.setRecording(isRecording, elapsed: text)
        content.badge.text = text
        content.needsLayout = true
        content.badge.animator().alphaValue = (isRecording && !overlayVisible) ? 1 : 0
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let success = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
        let message = error?.localizedDescription
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.recordingFinished(url: outputFileURL, success: success, message: message) }
        }
    }

    private func recordingFinished(url: URL, success: Bool, message: String?) {
        if success {
            lastRecording = url
            log("Recording saved to \(url.path)")
        } else {
            try? FileManager.default.removeItem(at: url)
            log("Recording failed. \(message ?? "")")
        }
        if isRecording { // it ended on its own (for example the device went away)
            isRecording = false
            recordTimer?.invalidate()
            updateRecordingUI()
        }
        if finalizing {
            finalizing = false
            Self.pendingFinalizations -= 1
            finishCapture()
        } else if !ended {
            flash(success ? "Saved" : "Failed")
        }
    }

    // MARK: Closing

    func windowWillClose(_ notification: Notification) {
        guard !ended else { return }
        ended = true
        hideTimer?.invalidate()
        flashTimer?.invalidate()
        recordTimer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        window.delegate = nil
        frameOutput.setSampleBufferDelegate(nil, queue: nil)

        if movieOutput.isRecording {
            finalizing = true
            Self.pendingFinalizations += 1
            isRecording = false
            movieOutput.stopRecording()
        } else {
            finishCapture()
        }
    }

    private func finishCapture() {
        let capture = capture
        queue.async { capture.stopRunning() }
        onEnd?(SessionEnd(failure: nil, revealURL: lastRecording))
        onEnd = nil
    }
}
