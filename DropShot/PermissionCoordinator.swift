import AppKit
import CoreGraphics
import ScreenCaptureKit

final class PermissionCoordinator {
    private static let screenRecordingSettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    private lazy var permissionWindowController = PermissionWindowController(
        onPrimaryAction: { [weak self] in
            self?.handlePrimaryAction()
        },
        onDismiss: { [weak self] in
            self?.handleDismiss()
        }
    )

    private let notificationCenter: NotificationCenter
    private var pollTimer: Timer?
    private var shouldOfferSettingsShortcut = false

    var hasScreenRecordingPermission: Bool {
        // CGPreflightScreenCaptureAccess() can return false after a rebuild even
        // when the user has already granted Screen Recording permission in System
        // Settings.  This happens because macOS ties TCC authorisation to the
        // binary's code signature, which changes on every development build.
        //
        // As a workaround we also accept permission if ScreenCaptureKit's
        // SCShareableContent succeeds, which is a live check that bypasses the
        // stale TCC cache.
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        // Synchronous probe: attempt to list shareable content.  If ScreenCaptureKit
        // returns content rather than an error the system *does* consider us authorised.
        var hasAccess = false
        let semaphore = DispatchSemaphore(value: 0)
        SCShareableContent.getWithCompletionHandler { content, error in
            hasAccess = (content != nil && error == nil)
            semaphore.signal()
        }
        // Timeout after 1 second so we never block the main thread indefinitely.
        _ = semaphore.wait(timeout: .now() + 1)
        return hasAccess
    }

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        notificationCenter.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        pollTimer?.invalidate()
        notificationCenter.removeObserver(self)
    }

    func ensureScreenRecordingPermission() -> Bool {
        guard !hasScreenRecordingPermission else {
            shouldOfferSettingsShortcut = false
            pollTimer?.invalidate()
            permissionWindowController.closeWindow()
            return true
        }

        permissionWindowController.present(for: currentStep)
        startPermissionPolling()
        return false
    }

    private var currentStep: PermissionWindowStep {
        shouldOfferSettingsShortcut ? .openSettings : .requestAccess
    }

    private func handlePrimaryAction() {
        switch currentStep {
        case .requestAccess:
            requestScreenRecordingPermission()
        case .openSettings:
            openScreenRecordingSettings()
        }
    }

    private func handleDismiss() {
        pollTimer?.invalidate()
        permissionWindowController.closeWindow()
    }

    private func requestScreenRecordingPermission() {
        shouldOfferSettingsShortcut = true
        permissionWindowController.present(for: .openSettings)
        startPermissionPolling()
        openScreenRecordingSettings()
    }

    private func startPermissionPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.handlePermissionStatusRefresh()
        }
    }

    private func openScreenRecordingSettings() {
        guard let settingsURL = URL(string: Self.screenRecordingSettingsURL) else {
            return
        }

        NSWorkspace.shared.open(settingsURL)
    }

    @objc
    private func handleApplicationDidBecomeActive(_ notification: Notification) {
        handlePermissionStatusRefresh()
    }

    private func handlePermissionStatusRefresh() {
        guard hasScreenRecordingPermission else {
            return
        }

        pollTimer?.invalidate()
        shouldOfferSettingsShortcut = false
        permissionWindowController.closeWindow()
    }
}
