import Foundation

final class CaptureSessionCoordinator {
    private let permissionCoordinator: PermissionCoordinator

    init(permissionCoordinator: PermissionCoordinator) {
        self.permissionCoordinator = permissionCoordinator
    }

    func beginCaptureSession() {
        guard permissionCoordinator.ensureScreenRecordingPermission() else {
            NSLog("Capture request blocked until Screen Recording permission is granted.")
            return
        }

        // Later milestones replace this stub with the real capture flow.
        NSLog("Capture session requested.")
    }
}
