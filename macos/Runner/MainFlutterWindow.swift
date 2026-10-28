import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  private var native: SnapLiteNative?

  override func awakeFromNib() {
    CaptureFiles.migrateOldFolder()   // before Flutter or the shell touch the captures folder
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    native = SnapLiteNative(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  // Menu bar app: the editor window starts hidden (window_manager's pattern, so the engine still starts).
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
    DockPresence.shared.update()   // show/hide don't post a notification of their own
  }
}


/// A menu bar app (LSUIElement) has no Dock icon, so an open editor couldn't be found with ⌘-Tab or
/// the Dock and sat over everything. While any normal window (editor, library, settings) is open or
/// minimized SnapLite becomes a regular app; when the last one goes away it's menu-bar only again.
final class DockPresence {
    static let shared = DockPresence()

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in self.update() }
        }
    }

    /// Deferred one turn so a closing or hiding window has left the screen before it's counted.
    func update() {
        DispatchQueue.main.async {
            let open = NSApp.windows.contains { w in
                w.styleMask.contains(.titled) && !(w is NSPanel) && w.level == .normal
                    && (w.isVisible || w.isMiniaturized)
            }
            let wanted: NSApplication.ActivationPolicy = open ? .regular : .accessory
            if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
        }
    }
}
