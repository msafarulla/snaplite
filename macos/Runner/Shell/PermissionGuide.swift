import AppKit

/// Screen Recording without the permission loop.
///
/// Downloaded builds are signed ad hoc, so macOS treats each update as a new app: the old switch in
/// System Settings stays on but no longer counts, and the user is asked again and again while the switch
/// already looks on. SnapNow remembers which build had permission; when a newer build finds it missing, it
/// clears the stale entry itself (`tccutil reset`) so one switch-on is enough. Either way the user gets one
/// clear window instead of a bare system prompt on every launch.
enum ScreenPermission {
    private static let grantedBuildKey = "screenPermission.grantedBuild"
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    static var granted: Bool { CGPreflightScreenCaptureAccess() }

    private static var build: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] ?? "")+\(info?["CFBundleVersion"] ?? "")"
    }

    /// At launch: remember a build that has permission; otherwise guide the user (and clear a stale entry first).
    static func checkAtLaunch() {
        if granted {
            UserDefaults.standard.set(build, forKey: grantedBuildKey)
            return
        }
        let before = UserDefaults.standard.string(forKey: grantedBuildKey)
        let updated = before != nil && before != build
        let cleared = updated && resetStaleEntry()
        CGRequestScreenCaptureAccess() // adds SnapNow to the list (the system shows its prompt once)
        PermissionGuide.shared.show(afterUpdate: updated, cleared: cleared)
    }

    /// Removes SnapNow's entry from Screen Recording, so the next switch-on applies to this copy of the app.
    @discardableResult
    static func resetStaleEntry() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "ScreenCapture", id]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Quits and opens SnapNow again (macOS applies a new Screen Recording switch on the next launch).
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// The one window that walks the user through Screen Recording: what to switch on, where, and a way out of
/// the loop if the switch already looks on. It notices when permission arrives and offers the relaunch.
final class PermissionGuide: NSWindowController {
    static let shared = PermissionGuide()

    private let stack = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Screen Recording for SnapNow"
        window.isReleasedWhenClosed = false
        window.level = .floating // stays visible next to System Settings
        super.init(window: window)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 460),
        ])

        let title = NSTextField(labelWithString: "SnapNow needs Screen Recording to capture your screen")
        title.font = .boldSystemFont(ofSize: 14)
        message.preferredMaxLayoutWidth = 412
        status.font = .systemFont(ofSize: 12, weight: .semibold)

        let open = NSButton(title: "Open System Settings", target: self, action: #selector(openSettings))
        open.keyEquivalent = "\r"
        let reset = NSButton(title: "It's Already On", target: self, action: #selector(resetAndRetry))
        reset.toolTip = "Clears SnapNow's old entry (left over from an earlier version), so switching it on works"
        let relaunch = NSButton(title: "Relaunch SnapNow", target: self, action: #selector(relaunchNow))
        let buttons = NSStackView(views: [open, reset, relaunch])
        buttons.spacing = 8

        [title, message, status, buttons].forEach(stack.addArrangedSubview)
        Theme.style(window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(afterUpdate: Bool = false, cleared: Bool = false) {
        message.stringValue = (afterUpdate
            ? "SnapNow was updated, and macOS needs Screen Recording switched on again for the new version. "
              + (cleared ? "The old entry has been cleared for you.\n\n"
                         : "If SnapNow is listed already, select it, click −, then switch it on again.\n\n")
            : "")
            + "1. Click Open System Settings.\n"
            + "2. Switch on SnapNow under Screen & System Audio Recording.\n"
            + "3. Click Relaunch SnapNow.\n\n"
            + "If SnapNow already looks switched on but this window keeps coming back, click It's Already On: "
            + "it clears the leftover entry, then switch SnapNow on once more."
        refresh()
        NSApp.activate()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        if ScreenPermission.granted {
            status.stringValue = "✓ Screen Recording is on. Click Relaunch SnapNow to finish."
            status.textColor = .systemGreen
        } else {
            status.stringValue = "Screen Recording: off"
            status.textColor = .secondaryLabelColor
        }
    }

    @objc private func openSettings() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(ScreenPermission.settingsURL)
    }

    @objc private func resetAndRetry() {
        let cleared = ScreenPermission.resetStaleEntry()
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(ScreenPermission.settingsURL)
        status.stringValue = cleared
            ? "Old entry cleared. Switch SnapNow on in System Settings, then click Relaunch SnapNow."
            : "Couldn't clear it automatically: in System Settings, select SnapNow, click −, then switch it on again."
        status.textColor = .labelColor
    }

    @objc private func relaunchNow() {
        ScreenPermission.relaunch()
    }

    override func close() {
        timer?.invalidate()
        timer = nil
        super.close()
    }
}
