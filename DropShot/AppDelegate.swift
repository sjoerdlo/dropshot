import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let permissionCoordinator = PermissionCoordinator()
    private lazy var captureSessionCoordinator = CaptureSessionCoordinator(
        permissionCoordinator: permissionCoordinator
    )
    private lazy var hotkeyManager = HotkeyManager { [weak self] in
        self?.startCaptureSession()
    }

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

        let captureItem = NSMenuItem(
            title: "Capture",
            action: #selector(handleCaptureAction(_:)),
            keyEquivalent: ""
        )
        captureItem.target = self
        statusMenu.addItem(captureItem)
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
    private func handleCaptureAction(_ sender: Any?) {
        startCaptureSession()
    }

    private func startCaptureSession() {
        captureSessionCoordinator.beginCaptureSession()
    }

    @objc
    private func quitApplication(_ sender: Any?) {
        NSApp.terminate(sender)
    }
}

final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let onCaptureRequested: () -> Void

    init(onCaptureRequested: @escaping () -> Void) {
        self.onCaptureRequested = onCaptureRequested
    }

    func register() {
        guard hotKeyRef == nil, eventHandlerRef == nil else {
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

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyIdentifier)
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_X),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registrationStatus == noErr else {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                self.eventHandlerRef = nil
            }

            NSLog("Failed to register capture hotkey: %d", registrationStatus)
            return
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

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

        guard hotKeyID.signature == Self.hotKeySignature, hotKeyID.id == Self.hotKeyIdentifier else {
            return noErr
        }

        let onCaptureRequested = self.onCaptureRequested
        DispatchQueue.main.async(execute: onCaptureRequested)
        return noErr
    }

    private static let hotKeySignature = fourCharacterCode("DSHT")
    private static let hotKeyIdentifier: UInt32 = 1
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
