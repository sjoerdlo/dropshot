import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let permissionCoordinator = PermissionCoordinator()
    private lazy var captureSessionCoordinator = CaptureSessionCoordinator(
        permissionCoordinator: permissionCoordinator
    )
    private lazy var hotkeyManager = HotkeyManager(handlers: [
        HotkeyManager.Hotkey(
            keyCode: UInt32(kVK_ANSI_3),
            modifiers: UInt32(cmdKey | shiftKey),
            id: 1
        ): { [weak self] in
            self?.captureSessionCoordinator.beginCaptureSession()
        },
        HotkeyManager.Hotkey(
            keyCode: UInt32(kVK_ANSI_4),
            modifiers: UInt32(cmdKey | shiftKey),
            id: 2
        ): { [weak self] in
            self?.captureSessionCoordinator.beginQuickCapture()
        }
    ])

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configureMenu()
        hotkeyManager.register()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "DropShot"
        item.menu = statusMenu
        statusItem = item
    }

    private func configureMenu() {
        statusMenu.removeAllItems()

        let scrollCaptureItem = NSMenuItem(
            title: "Scroll Capture (⌘⇧3)",
            action: #selector(handleScrollCaptureAction(_:)),
            keyEquivalent: ""
        )
        scrollCaptureItem.target = self
        statusMenu.addItem(scrollCaptureItem)

        let quickCaptureItem = NSMenuItem(
            title: "Quick Capture (⌘⇧4)",
            action: #selector(handleQuickCaptureAction(_:)),
            keyEquivalent: ""
        )
        quickCaptureItem.target = self
        statusMenu.addItem(quickCaptureItem)

        statusMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit DropShot",
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    @objc
    private func handleScrollCaptureAction(_ sender: Any?) {
        captureSessionCoordinator.beginCaptureSession()
    }

    @objc
    private func handleQuickCaptureAction(_ sender: Any?) {
        captureSessionCoordinator.beginQuickCapture()
    }

    @objc
    private func quitApplication(_ sender: Any?) {
        NSApp.terminate(sender)
    }
}

final class HotkeyManager {
    struct Hotkey: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
        let id: UInt32
    }

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private let handlers: [Hotkey: () -> Void]

    init(handlers: [Hotkey: () -> Void]) {
        self.handlers = handlers
    }

    func register() {
        guard eventHandlerRef == nil else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyEventHandler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )

        guard handlerStatus == noErr else {
            NSLog("Failed to install hotkey handler: %d", handlerStatus)
            return
        }

        for hotkey in handlers.keys {
            let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: hotkey.id)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                hotkey.keyCode,
                hotkey.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )

            if status == noErr, let ref {
                hotKeyRefs[hotkey.id] = ref
            } else {
                NSLog("Failed to register hotkey %d: %d", hotkey.id, status)
            }
        }
    }

    func unregister() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    deinit {
        unregister()
    }

    private func handleHotKeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event else {
            return noErr
        }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else {
            return status
        }

        guard hotKeyID.signature == Self.hotKeySignature else {
            return noErr
        }

        // Find the handler for this hotkey ID
        if let hotkey = handlers.keys.first(where: { $0.id == hotKeyID.id }),
           let handler = handlers[hotkey] {
            DispatchQueue.main.async(execute: handler)
        }

        return noErr
    }

    private static let hotKeySignature = fourCharacterCode("DSHT")
    private static let hotKeyEventHandler: EventHandlerUPP = { _, event, userData in
        guard let userData else {
            return noErr
        }

        let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        return manager.handleHotKeyEvent(event)
    }

    private static func fourCharacterCode(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
