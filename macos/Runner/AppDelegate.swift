import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // FlutterAppDelegate has no applicationDidFinishLaunching of its own, so no super call (it throws).
  override func applicationDidFinishLaunching(_ notification: Notification) {
    Shell.shared.start()   // status item, capture panel, menu, hotkeys
    NSWindow.allowsAutomaticWindowTabbing = false   // no Show Tab Bar / Show All Tabs in the View menu
  }

  // Menu bar app: closing the editor window only hides it.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // Dock icon clicked while every window is hidden (e.g. ⌘W in the editor): bring the Library back.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { Shell.shared.showLibrary() }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
