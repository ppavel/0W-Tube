import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMenu.install(appName: "0W-Tube")

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "0W-Tube"
        // Без этого ⌃⌘F и зеленая кнопка разворачивают окно, а не уводят в Space.
        window.collectionBehavior.insert(.fullScreenPrimary)
        // Размер и позиция окна запоминаются между запусками, как принято в macOS;
        // при первом запуске сохраненного кадра еще нет, и окно встает по центру.
        window.setFrameAutosaveName("main")
        if !window.setFrameUsingName("main") { window.center() }

        window.contentView = NSHostingView(rootView: ContentView())
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}