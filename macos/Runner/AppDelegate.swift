import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // FlutterAppDelegate has no applicationDidFinishLaunching of its own, so no super call (it throws).
  override func applicationDidFinishLaunching(_ notification: Notification) {
    Shell.shared.start()   // status item, capture panel, menu, hotkeys
  }

  // Menu bar app: closing the editor window only hides it.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
