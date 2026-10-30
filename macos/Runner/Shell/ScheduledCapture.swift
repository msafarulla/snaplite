import AppKit
import ScreenCaptureKit

/// Scheduled screenshots: every few seconds or minutes, each screen is saved to `<folder>/yyyyMMdd/HHmmss.png`
/// (other screens get `-2`, `-3`…). Runs until stopped, survives a relaunch, and skips turns while the screen
/// is locked. Shoots with ScreenCaptureKit in SnapNow itself, which has the Screen Recording permission.
final class ScheduledCapture: NSObject, NSMenuDelegate {
    static let shared = ScheduledCapture()

    static let intervals: [(String, TimeInterval)] = [
        ("Every 10 Seconds", 10), ("Every 30 Seconds", 30), ("Every Minute", 60), ("Every 5 Minutes", 300),
        ("Every 15 Minutes", 900), ("Every 30 Minutes", 1800), ("Every Hour", 3600),
    ]

    /// The menu bar icon follows whether it's running.
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var last: Date?
    private var shooting = false
    private let menu = NSMenu()

    var isRunning: Bool { timer != nil }

    var interval: TimeInterval {
        get { let v = defaults.double(forKey: "schedule.interval"); return v > 0 ? v : 60 }
        set { defaults.set(newValue, forKey: "schedule.interval") }
    }

    var folder: URL {
        get {
            if let path = defaults.string(forKey: "schedule.folder") { return URL(fileURLWithPath: path, isDirectory: true) }
            let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            return pictures.appendingPathComponent("SnapNow Scheduled", isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: "schedule.folder") }
    }

    /// At launch: carry on if it was running when SnapNow quit, and say so (never silently).
    func resumeIfRunning() {
        guard defaults.bool(forKey: "schedule.running") else { return }
        start(announce: false)
        Toast.show("Scheduled screenshots resumed: \(Self.label(interval).lowercased())", symbol: "camera.badge.clock",
                   footnote: "Stop them in the menu bar › Scheduled Screenshots")
    }

    func start(announce: Bool = true) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.shoot() }
        t.tolerance = min(1, interval / 10)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        defaults.set(true, forKey: "schedule.running")
        shoot() // the first one straight away
        if announce { Toast.show("Scheduled screenshots: \(Self.label(interval).lowercased())", symbol: "camera.badge.clock") }
        onChange?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        defaults.set(false, forKey: "schedule.running")
        Toast.show("Scheduled screenshots stopped", symbol: "stop.circle")
        onChange?()
    }

    private static func label(_ seconds: TimeInterval) -> String {
        intervals.first { $0.1 == seconds }?.0 ?? "Every \(Int(seconds)) Seconds"
    }

    // MARK: Shooting

    private func shoot() {
        guard !shooting, CGPreflightScreenCaptureAccess(), !Self.screenLocked else { return }
        shooting = true
        let now = Date()
        Task { @MainActor in
            defer { shooting = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            let day = DateFormatter(), time = DateFormatter()
            day.dateFormat = "yyyyMMdd"
            time.dateFormat = "HHmmss"
            let dir = folder.appendingPathComponent(day.string(from: now), isDirectory: true)
            guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return }
            var saved = false
            for (i, screen) in NSScreen.screens.enumerated() {
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                      let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                let config = SCStreamConfiguration()
                config.width = Int(screen.frame.width * screen.backingScaleFactor)
                config.height = Int(screen.frame.height * screen.backingScaleFactor)
                config.showsCursor = false
                config.captureResolution = .best
                guard let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config) else { continue }
                let base = time.string(from: now) + (i == 0 ? "" : "-\(i + 1)")
                saved = Self.write(image, to: Capture.uniqueURL(in: dir, base: base), scale: screen.backingScaleFactor) || saved
            }
            if saved { last = now }
        }
    }

    private static func write(_ image: CGImage, to url: URL, scale: CGFloat) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// Locked (or at the login window): nothing worth saving, so the turn is skipped.
    private static var screenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // MARK: Menu

    /// "Scheduled Screenshots ›" for the menu bar menu: start/stop, how often, and where they go.
    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Scheduled Screenshots", action: nil, keyEquivalent: "")
        menu.delegate = self
        item.submenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?, tag: Int = 0, on: Bool = false) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.tag = tag
            entry.state = on ? .on : .off
            entry.isEnabled = action != nil
            menu.addItem(entry)
            return entry
        }
        _ = add(isRunning ? "Stop Scheduled Screenshots" : "Start Scheduled Screenshots", #selector(toggle))
        if isRunning, let last {
            let f = DateFormatter()
            f.timeStyle = .medium
            _ = add("Last: \(f.string(from: last))", nil)
        }
        menu.addItem(.separator())
        for (i, entry) in Self.intervals.enumerated() {
            _ = add(entry.0, #selector(intervalChosen(_:)), tag: i, on: entry.1 == interval)
        }
        menu.addItem(.separator())
        _ = add("Save to: \((folder.path as NSString).abbreviatingWithTildeInPath)", nil)
        _ = add("Choose Folder…", #selector(chooseFolder))
        _ = add("Open Folder", #selector(openFolder))
    }

    @objc private func toggle() { isRunning ? stop() : start() }

    @objc private func intervalChosen(_ sender: NSMenuItem) {
        interval = Self.intervals[sender.tag].1
        if isRunning { start() } // the new pace from now
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Scheduled screenshots go into a folder per day (yyyyMMdd), named by time (HHmmss.png)."
        panel.directoryURL = folder
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
