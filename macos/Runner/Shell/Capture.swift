import AppKit

enum CaptureMode {
    case region, window, screen
}

extension Notification.Name {
    /// Posted when a file in the captures folder is added or changed.
    static let capturesChanged = Notification.Name("SnapLiteCapturesChanged")
}

enum Capture {
    static let folder: URL = {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        let url = pictures.appendingPathComponent("SnapNow", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Scratch space for drag-out, sharing and text grabs.
    static let cacheFolder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("SnapLite", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func isInFolder(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path
    }

    /// A free file name, e.g. "SnapNow 2026-10-20 at 14.05.33.png", then "... 2.png".
    static func uniqueURL(in directory: URL = folder, base: String, ext: String = "png") -> URL {
        var url = directory.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    static func newCaptureURL(prefix: String = "SnapNow", ext: String = "png") -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return uniqueURL(base: "\(prefix) \(f.string(from: Date()))", ext: ext)
    }

    /// Runs /usr/sbin/screencapture; completion gets the new file, or nil if the user pressed Esc.
    /// `cursor` only works for full-screen captures (screencapture -C is non-interactive only).
    static func run(_ mode: CaptureMode, to destination: URL? = nil, cursor: Bool = false, windowShadow: Bool = false,
                    sound: Bool = false, completion: @escaping (URL?) -> Void) {
        let url = destination ?? newCaptureURL()
        var args = sound ? [] : ["-x"]
        if !windowShadow { args.append("-o") }       // window captures (also Space in region mode) without the shadow
        switch mode {
        case .region: args += ["-i"]               // drag a region; Space switches to window picking
        case .window: args += ["-i", "-w"]         // pick a window
        case .screen: args += ["-D", String(displayUnderMouse())] + (cursor ? ["-C"] : [])
        }
        args.append(url.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = args
        process.terminationHandler = { _ in
            let captured = FileManager.default.fileExists(atPath: url.path)
            DispatchQueue.main.async { completion(captured ? url : nil) }
        }
        do {
            try process.run()
        } catch {
            completion(nil)
        }
    }

    /// screencapture numbers displays from 1, main display first, matching NSScreen.screens.
    private static func displayUnderMouse() -> Int {
        let mouse = NSEvent.mouseLocation
        let index = NSScreen.screens.firstIndex { NSMouseInRect(mouse, $0.frame, false) } ?? 0
        return index + 1
    }
}
