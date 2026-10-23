import AppKit

/// A short notice near the bottom of the screen that fades on its own. It can carry a preview of
/// copied text (`detail`); it stays while the mouse is over it and never takes focus.
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, symbol: String = "checkmark.circle.fill", detail: String? = nil, footnote: String? = nil) {
        panel?.orderOut(nil)
        hideWork?.cancel()

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Theme.accent
        let title = NSTextField(labelWithString: message)
        title.font = Theme.font(13, bold: detail != nil)
        title.textColor = Theme.text
        let header = NSStackView(views: [icon, title])
        header.spacing = 8

        let stack = NSStackView(views: [header])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 11, right: 16)
        if let detail {
            // The copied text itself: up to three lines, monospaced so codes and commands read clearly
            let lines = detail.split(separator: "\n", omittingEmptySubsequences: false)
            var preview = lines.prefix(3).joined(separator: "\n")
            if lines.count > 3 { preview += "\n…" }
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let body = NSTextField(wrappingLabelWithString: preview)
            body.font = font
            body.textColor = Theme.dimText
            body.maximumNumberOfLines = 4
            body.lineBreakMode = .byTruncatingTail
            // Size to the text (up to 560 pt) so the right edge keeps its padding
            let widest = preview.split(separator: "\n").map { (String($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            let width = min(ceil(widest) + 14, 560)
            body.preferredMaxLayoutWidth = width
            body.widthAnchor.constraint(equalToConstant: width).isActive = true
            stack.addArrangedSubview(body)
        }
        if let footnote {
            let note = NSTextField(labelWithString: footnote)
            note.font = Theme.font(11)
            note.textColor = Theme.muted
            stack.addArrangedSubview(note)
        }

        let background = HoverView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.layer?.borderColor = Theme.border.cgColor
        background.layer?.borderWidth = 1
        if Theme.isGlass {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(blur)
            NSLayoutConstraint.activate([
                blur.leadingAnchor.constraint(equalTo: background.leadingAnchor),
                blur.trailingAnchor.constraint(equalTo: background.trailingAnchor),
                blur.topAnchor.constraint(equalTo: background.topAnchor),
                blur.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            ])
        } else {
            background.layer?.backgroundColor = Theme.raised.withAlphaComponent(0.97).cgColor
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        let size = stack.fittingSize
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let p = NSPanel(contentRect: NSRect(x: screen.midX - size.width / 2, y: screen.minY + 80, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = detail == nil   // text previews can be hovered to keep them up
        p.appearance = Theme.appearance
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.contentView = background
        p.orderFrontRegardless()
        panel = p

        let duration: TimeInterval = detail == nil ? 1.8 : 4.5
        background.onHover = { inside in
            hideWork?.cancel()
            if !inside { scheduleHide(p, after: 1.5) }
        }
        scheduleHide(p, after: duration)
    }

    private static func scheduleHide(_ p: NSPanel, after seconds: TimeInterval) {
        let work = DispatchWorkItem {
            guard panel === p else { return }
            p.orderOut(nil)
            panel = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Reports the mouse entering and leaving, so a toast can stay up while you read it.
private final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
