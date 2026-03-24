import AppKit
import CoreGraphics

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

    private var shouldOfferSettingsShortcut = false

    func ensureScreenRecordingPermission() -> Bool {
        guard !CGPreflightScreenCaptureAccess() else {
            shouldOfferSettingsShortcut = false
            permissionWindowController.closeWindow()
            return true
        }

        permissionWindowController.present(for: currentStep)
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
        permissionWindowController.closeWindow()
    }

    private func requestScreenRecordingPermission() {
        let granted = CGRequestScreenCaptureAccess() || CGPreflightScreenCaptureAccess()
        guard !granted else {
            shouldOfferSettingsShortcut = false
            permissionWindowController.closeWindow()
            return
        }

        shouldOfferSettingsShortcut = true
        permissionWindowController.present(for: .openSettings)
    }

    private func openScreenRecordingSettings() {
        guard let settingsURL = URL(string: Self.screenRecordingSettingsURL) else {
            return
        }

        permissionWindowController.closeWindow()
        NSWorkspace.shared.open(settingsURL)
    }
}
