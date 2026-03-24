import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

protocol ScreenCaptureManaging {
    func captureStillImage(
        for displayID: CGDirectDisplayID,
        completion: @escaping (Result<CGImage, Error>) -> Void
    )
}

final class CaptureSessionCoordinator {
    struct StillImage {
        let screen: NSScreen
        let displayID: CGDirectDisplayID
        let image: CGImage
    }

    typealias StillImageCompletion = (Result<StillImage, Error>) -> Void

    private let permissionCoordinator: PermissionCoordinator
    private let screenCaptureManager: ScreenCaptureManaging

    var onStillImageReady: ((StillImage) -> Void)?

    init(
        permissionCoordinator: PermissionCoordinator,
        screenCaptureManager: ScreenCaptureManaging = ScreenCaptureManager()
    ) {
        self.permissionCoordinator = permissionCoordinator
        self.screenCaptureManager = screenCaptureManager
    }

    func beginCaptureSession() {
        captureStillImageForActiveScreen { [weak self] result in
            switch result {
            case .success(let stillImage):
                if let onStillImageReady = self?.onStillImageReady {
                    onStillImageReady(stillImage)
                } else {
                    NSLog(
                        "Captured still image for display \(stillImage.displayID) (\(stillImage.image.width)x\(stillImage.image.height))."
                    )
                }
            case .failure(let error):
                NSLog("Still capture failed: \(error.localizedDescription)")
            }
        }
    }

    func captureStillImageForActiveScreen(completion: @escaping StillImageCompletion) {
        guard permissionCoordinator.ensureScreenRecordingPermission() else {
            complete(completion, with: .failure(ScreenCaptureError.permissionRequired))
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        guard let screen = activeScreenUnderCursor(at: mouseLocation) else {
            complete(
                completion,
                with: .failure(ScreenCaptureError.activeScreenUnavailable(point: mouseLocation))
            )
            return
        }

        guard let displayID = screen.displayID else {
            complete(completion, with: .failure(ScreenCaptureError.screenDisplayUnavailable))
            return
        }

        screenCaptureManager.captureStillImage(for: displayID) { [screen] result in
            let mappedResult = result.map { image in
                StillImage(screen: screen, displayID: displayID, image: image)
            }
            self.complete(completion, with: mappedResult)
        }
    }

    private func activeScreenUnderCursor(at mouseLocation: NSPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        }
    }

    private func complete(_ completion: @escaping StillImageCompletion, with result: Result<StillImage, Error>) {
        if Thread.isMainThread {
            completion(result)
        } else {
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}

final class ScreenCaptureManager: ScreenCaptureManaging {
    func captureStillImage(
        for displayID: CGDirectDisplayID,
        completion: @escaping (Result<CGImage, Error>) -> Void
    ) {
        SCShareableContent.getWithCompletionHandler { shareableContent, error in
            if let error {
                completion(.failure(ScreenCaptureError.shareableContentLookupFailed(underlying: error)))
                return
            }

            guard let shareableContent else {
                completion(.failure(ScreenCaptureError.shareableDisplayUnavailable(displayID: displayID)))
                return
            }

            guard let display = shareableContent.displays.first(where: { $0.displayID == displayID }) else {
                completion(.failure(ScreenCaptureError.shareableDisplayUnavailable(displayID: displayID)))
                return
            }

            guard let displayMode = CGDisplayCopyDisplayMode(displayID) else {
                completion(.failure(ScreenCaptureError.displayModeUnavailable(displayID: displayID)))
                return
            }

            let configuration = SCStreamConfiguration()
            configuration.width = displayMode.pixelWidth
            configuration.height = displayMode.pixelHeight
            configuration.showsCursor = false

            let filter = SCContentFilter(display: display, excludingWindows: [])
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    completion(.failure(ScreenCaptureError.captureFailed(displayID: displayID, underlying: error)))
                    return
                }

                guard let image else {
                    completion(.failure(ScreenCaptureError.imageUnavailable(displayID: displayID)))
                    return
                }

                completion(.success(image))
            }
        }
    }
}

private enum ScreenCaptureError: LocalizedError {
    case permissionRequired
    case activeScreenUnavailable(point: NSPoint)
    case screenDisplayUnavailable
    case shareableContentLookupFailed(underlying: Error)
    case shareableDisplayUnavailable(displayID: CGDirectDisplayID)
    case displayModeUnavailable(displayID: CGDirectDisplayID)
    case captureFailed(displayID: CGDirectDisplayID, underlying: Error)
    case imageUnavailable(displayID: CGDirectDisplayID)

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Screen Recording permission is required before capturing."
        case .activeScreenUnavailable(let point):
            return "No screen was found under the cursor at \(point)."
        case .screenDisplayUnavailable:
            return "The active AppKit screen could not be mapped to a display ID."
        case .shareableContentLookupFailed(let underlying):
            return "ScreenCaptureKit could not enumerate shareable content: \(underlying.localizedDescription)"
        case .shareableDisplayUnavailable(let displayID):
            return "The active display \(displayID) was not available to ScreenCaptureKit."
        case .displayModeUnavailable(let displayID):
            return "The active display \(displayID) did not report a capture size."
        case .captureFailed(let displayID, let underlying):
            return "Still capture failed for display \(displayID): \(underlying.localizedDescription)"
        case .imageUnavailable(let displayID):
            return "Still capture for display \(displayID) completed without an image."
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return CGDirectDisplayID(screenNumber.uint32Value)
    }
}
