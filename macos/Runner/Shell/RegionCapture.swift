import Cocoa
import ScreenCaptureKit

/// Region capture in the style of Snagit: the screen freezes and dims, dashed crosshair lines follow the
/// cursor, the window under it is outlined, and a magnifier shows the pixels and the size. Drag for an
/// area, click for the outlined window (or the whole screen), Esc cancels. Drags stay on the screen they
/// start on. The capture is cut from the frozen image, so it matches what was on screen when it began.
final class RegionCapture {
    private static var current: RegionCapture?

    struct Frozen {
        let screen: NSScreen
        let image: CGImage
        var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
    }

    private var frozen: [Frozen] = []
    private var windows: [CGRect] = []        // Cocoa global coordinates, front to back
    private var overlays: [NSWindow] = []
    private var views: [RegionView] = []
    private var completion: ((URL?) -> Void)?
    private var url: URL!
    private var sound = false
    private var previousApp: NSRunningApplication?   // where Esc returns to

    var mouse = NSEvent.mouseLocation
    var dragStart: CGPoint?
    var dragScreen: NSScreen?

    /// `fallback` runs instead when the screen can't be frozen (no image, or a blank one).
    static func start(to url: URL, sound: Bool, completion: @escaping (URL?) -> Void, fallback: @escaping () -> Void) {
        current?.finish(nil)
        let capture = RegionCapture()
        capture.url = url
        capture.sound = sound
        capture.completion = completion
        let front = NSWorkspace.shared.frontmostApplication
        capture.previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        current = capture
        Task { @MainActor in
            // ScreenCaptureKit runs in SnapNow itself, so it has SnapNow's Screen Recording permission (a
            // screencapture child process came back empty on macOS 27); screencapture is the backup.
            let ok = await capture.freezeWithScreenCaptureKit() || capture.freeze()
            guard ok, current === capture else { if current === capture { current = nil }; fallback(); return }
            capture.snapshotWindows()
            capture.show()
        }
    }

    /// Each screen's display by ID, at its full pixel size.
    @MainActor private func freezeWithScreenCaptureKit() async -> Bool {
        frozen = []
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return false }
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { return false }
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            config.captureResolution = .best
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config),
                  !Self.isBlank(image) else { frozen = []; return false }
            frozen.append(Frozen(screen: screen, image: image))
        }
        return !frozen.isEmpty
    }

    /// An image with nothing in it (no permission, or a failed capture): every sampled pixel is black or clear.
    private static func isBlank(_ image: CGImage) -> Bool {
        let n = 24
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        return stride(from: 0, to: px.count, by: 4).allSatisfy { px[$0] == 0 && px[$0 + 1] == 0 && px[$0 + 2] == 0 }
    }

    // MARK: Freezing

    /// Each screen by its exact frame (screencapture -R takes points from the main display's top-left), so
    /// every image belongs to a known screen; BMP because it's written in ~0.1 s.
    private func freeze() -> Bool {
        frozen = []
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            let f = screen.frame
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("snapnow-freeze-\(UUID().uuidString).bmp")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-t", "bmp", "-R\(Int(f.minX)),\(Int(mainHeight - f.maxY)),\(Int(f.width)),\(Int(f.height))", tmp.path]
            do { try p.run() } catch { return false }
            p.waitUntilExit()
            guard let source = CGImageSourceCreateWithURL(tmp as CFURL, nil),
                  let raw = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary),
                  let image = Self.opaque(raw),
                  abs(CGFloat(image.width) / f.width - CGFloat(image.height) / f.height) < 0.05 else { return false }
            guard !Self.isBlank(image) else { frozen = []; return false }
            frozen.append(Frozen(screen: screen, image: image))
        }
        return !frozen.isEmpty
    }

    /// The windows on screen now, front to back, for click-to-capture-a-window.
    private func snapshotWindows() {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        windows = list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? pid_t) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
                  r.width > 40, r.height > 40 else { return nil }
            return CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
        }
    }

    /// The same pixels with the alpha channel ignored: screencapture's BMP can come with alpha 0 everywhere,
    /// which drew as a white (empty) screen and saved blank captures. No copy; only the format changes.
    private static func opaque(_ image: CGImage) -> CGImage? {
        let skip: CGImageAlphaInfo
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        case .premultipliedFirst, .first: skip = .noneSkipFirst
        default: skip = .noneSkipLast
        }
        let info = (image.bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue) | skip.rawValue
        guard let space = image.colorSpace, let provider = image.dataProvider else { return image }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: image.bitsPerComponent,
                       bitsPerPixel: image.bitsPerPixel, bytesPerRow: image.bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Overlays

    private func show() {
        for f in frozen {
            let window = KeyPanel(contentRect: f.screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = true
            window.backgroundColor = .black   // never a white flash if the frozen screen were missing
            window.hasShadow = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // The frozen screen is a layer (drawn by the GPU, once); the view above it draws only the overlay
            let size = CGRect(origin: .zero, size: f.screen.frame.size)
            let still = NSView(frame: size)
            still.wantsLayer = true
            still.layer?.contents = f.image
            still.layer?.contentsGravity = .resize
            let view = RegionView(frame: size, capture: self, frozen: f)
            still.addSubview(view)
            window.contentView = still
            window.setFrame(f.screen.frame, display: false)
            window.orderFrontRegardless()
            overlays.append(window)
            views.append(view)
        }
        // No NSApp.activate: the panels take the keys (Esc) without activating SnapNow, so an open editor stays
        // where it is and Esc leaves you in the app you were using
        let screen = screenUnderMouse()
        if let i = frozen.firstIndex(where: { $0.screen == screen }) {
            overlays[i].makeKey()
            overlays[i].makeFirstResponder(views[i])
        }
        NSCursor.crosshair.push()
        redraw()
    }

    func screenUnderMouse() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    func redraw() { views.forEach { $0.needsDisplay = true } }

    /// The drag rectangle (global), clamped to the screen it started on.
    var selection: CGRect? {
        guard let a = dragStart, let screen = dragScreen else { return nil }
        let r = CGRect(x: min(a.x, mouse.x), y: min(a.y, mouse.y), width: abs(a.x - mouse.x), height: abs(a.y - mouse.y))
        return r.intersection(screen.frame)
    }

    var isDragging: Bool {
        guard let r = selection else { return false }
        return r.width >= 4 || r.height >= 4
    }

    /// The front window under the cursor, cut to its screen.
    var hoveredWindow: CGRect? {
        guard let screen = screenUnderMouse() else { return nil }
        return windows.first { $0.contains(mouse) }.map { $0.intersection(screen.frame) }
    }

    /// What a click would capture right now (or the selection while dragging).
    var focus: CGRect? { isDragging ? selection : hoveredWindow }

    // MARK: Finishing

    func mouseUp() {
        guard let screen = dragScreen else { return }
        let rect = isDragging ? selection : (hoveredWindow ?? screen.frame)
        dragStart = nil
        guard let r = rect, r.width >= 1, r.height >= 1, let f = frozen.first(where: { $0.screen == screen }) else { finish(nil); return }
        finish(save(r, from: f) ? url : nil)
    }

    /// Esc: closes the overlay and goes back to the app you were in (starting from the menu bar panel
    /// had made SnapNow active).
    func cancel() {
        let back = previousApp
        finish(nil)
        if NSApp.isActive { back?.activate() }
    }

    private func save(_ r: CGRect, from f: Frozen) -> Bool {
        let s = f.scale, sf = f.screen.frame
        let pixels = CGRect(x: (r.minX - sf.minX) * s, y: (sf.maxY - r.maxY) * s, width: r.width * s, height: r.height * s).integral
        guard let crop = f.image.cropping(to: pixels),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        // Retina captures carry their density, as screencapture's files do
        CGImageDestinationAddImage(dest, crop, [kCGImagePropertyDPIWidth: 72 * s, kCGImagePropertyDPIHeight: 72 * s] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    private func finish(_ result: URL?) {
        guard completion != nil else { return }
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        views = []
        NSCursor.pop()
        if result != nil && sound {
            NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true)?.play()
        }
        let done = completion
        completion = nil
        RegionCapture.current = nil
        done?(result)
    }
}

/// A non-activating panel that can still become key: it gets Esc while the app you were in stays active.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class RegionView: NSView {
    private unowned let capture: RegionCapture
    private let frozen: RegionCapture.Frozen
    private static let orange = NSColor(srgbRed: 0.98, green: 0.62, blue: 0.13, alpha: 1)
    private static let loupe: CGFloat = 150, cells: CGFloat = 19   // magnifier size; pixels across it

    init(frame: CGRect, capture: RegionCapture, frozen: RegionCapture.Frozen) {
        self.capture = capture
        self.frozen = frozen
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    private var origin: CGPoint { frozen.screen.frame.origin }
    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -origin.x, dy: -origin.y) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let focus = capture.focus.flatMap { r -> CGRect? in
            let l = local(r)
            return l.intersects(bounds) ? l : nil
        }

        // Dim all but the focus
        let dim = NSBezierPath(rect: bounds)
        if let f = focus { dim.appendRect(f) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.4).setFill()
        dim.fill()

        let m = CGPoint(x: capture.mouse.x - origin.x, y: capture.mouse.y - origin.y)
        guard bounds.contains(m) else { return }

        if !capture.isDragging {
            let lines = NSBezierPath()
            lines.move(to: CGPoint(x: bounds.minX, y: m.y)); lines.line(to: CGPoint(x: bounds.maxX, y: m.y))
            lines.move(to: CGPoint(x: m.x, y: bounds.minY)); lines.line(to: CGPoint(x: m.x, y: bounds.maxY))
            lines.lineWidth = 1
            lines.setLineDash([8, 6], count: 2, phase: 0)
            Self.orange.withAlphaComponent(0.9).setStroke()
            lines.stroke()
        }

        // The selection's size while dragging, otherwise where the cursor is (points from the screen's top-left)
        let size = capture.isDragging
            ? focus.map { "\(Int($0.width.rounded())) x \(Int($0.height.rounded()))" } ?? ""
            : "x = \(Int(m.x))   y = \(Int(bounds.height - m.y))"
        let loupeRect = drawLoupe(at: m, ctx: ctx, label: size)
        if capture.dragStart == nil { hint("Click, hold, and drag to select region", beside: loupeRect) }
    }

    /// The magnifier below the cursor (above it near the bottom edge), with the size under it.
    private func drawLoupe(at m: CGPoint, ctx: CGContext, label: String) -> CGRect {
        let d = Self.loupe, gap: CGFloat = 36, labelH: CGFloat = 26
        var y = m.y - gap - d
        if y - labelH < 8 { y = m.y + gap }
        let x = min(max(m.x - d / 2, 8), bounds.maxX - d - 8)
        let circle = CGRect(x: x, y: y, width: d, height: d)

        // Card behind the circle and label, as in Snagit
        // As wide as the label needs (row/column can be wider than the circle)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let text = label as NSString
        let ts = text.size(withAttributes: attributes)
        let cardW = max(d + 12, ts.width + 24)
        let card = CGRect(x: circle.midX - cardW / 2, y: circle.minY - labelH, width: cardW, height: d + labelH + 6)
        let cardPath = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 8; shadow.shadowColor = NSColor.black.withAlphaComponent(0.4); shadow.set()
        NSColor(white: 0.12, alpha: 0.92).setFill()
        cardPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Pixels around the cursor, magnified without smoothing
        let s = frozen.scale, cells = Self.cells
        let px = CGRect(x: (m.x * s).rounded(.down) - (cells - 1) / 2, y: ((bounds.height - m.y) * s).rounded(.down) - (cells - 1) / 2,
                        width: cells, height: cells)
        ctx.saveGState()
        ctx.addEllipse(in: circle)
        ctx.clip()
        NSColor.white.setFill()
        circle.fill()
        if let crop = frozen.image.cropping(to: px.intersection(CGRect(x: 0, y: 0, width: frozen.image.width, height: frozen.image.height))) {
            ctx.interpolationQuality = .none
            let cell = d / cells
            // A crop clipped at the screen's edge keeps its place in the grid
            let dx = (max(px.minX, 0) - px.minX) * cell, dyTop = (max(px.minY, 0) - px.minY) * cell
            let w = CGFloat(crop.width) * cell, h = CGFloat(crop.height) * cell
            ctx.draw(crop, in: CGRect(x: circle.minX + dx, y: circle.maxY - dyTop - h, width: w, height: h))
        }
        // Pixel grid and the centre cross
        let cell = d / cells
        let grid = NSBezierPath()
        for i in 0...Int(cells) {
            let o = CGFloat(i) * cell
            grid.move(to: CGPoint(x: circle.minX + o, y: circle.minY)); grid.line(to: CGPoint(x: circle.minX + o, y: circle.maxY))
            grid.move(to: CGPoint(x: circle.minX, y: circle.minY + o)); grid.line(to: CGPoint(x: circle.maxX, y: circle.minY + o))
        }
        grid.lineWidth = 0.5
        NSColor(white: 0.5, alpha: 0.35).setStroke()
        grid.stroke()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: circle.minX, y: circle.midY)); cross.line(to: CGPoint(x: circle.maxX, y: circle.midY))
        cross.move(to: CGPoint(x: circle.midX, y: circle.minY)); cross.line(to: CGPoint(x: circle.midX, y: circle.maxY))
        cross.lineWidth = 2
        Self.orange.setStroke()
        cross.stroke()
        ctx.restoreGState()

        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 3
        NSColor.white.setStroke()
        ring.stroke()

        text.draw(at: CGPoint(x: circle.midX - ts.width / 2, y: card.minY + (labelH - ts.height) / 2 + 1), withAttributes: attributes)
        return card
    }

    private func hint(_ text: String, beside card: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.white]
        let ts = (text as NSString).size(withAttributes: attributes)
        var box = CGRect(x: card.minX - ts.width - 40, y: card.maxY - ts.height - 30, width: ts.width + 28, height: ts.height + 14)
        if box.minX < 8 { box.origin.x = card.maxX + 12 }
        let pill = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        NSColor(white: 0.12, alpha: 0.88).setFill()
        pill.fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 14, y: box.minY + 7), withAttributes: attributes)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseMoved(with event: NSEvent) {
        capture.mouse = NSEvent.mouseLocation
        capture.redraw()
    }

    override func mouseDown(with event: NSEvent) {
        capture.mouse = NSEvent.mouseLocation
        capture.dragStart = capture.mouse
        capture.dragScreen = capture.screenUnderMouse()
        capture.redraw()
    }

    override func mouseDragged(with event: NSEvent) {
        capture.mouse = NSEvent.mouseLocation
        capture.redraw()
    }

    override func mouseUp(with event: NSEvent) {
        capture.mouse = NSEvent.mouseLocation
        capture.mouseUp()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { capture.cancel() } else { super.keyDown(with: event) }
    }
}
