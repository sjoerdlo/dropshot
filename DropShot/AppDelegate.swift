import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configureMenu()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "DropShot"
        item.menu = statusMenu
        statusItem = item
    }

    private func configureMenu() {
        statusMenu.removeAllItems()
        statusMenu.addItem(
            withTitle: "Quit DropShot",
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
    }

    @objc
    private func quitApplication(_ sender: Any?) {
        NSApp.terminate(sender)
    }
}
