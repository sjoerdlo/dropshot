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

enum ScreenCaptureError: LocalizedError {
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

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return CGDirectDisplayID(screenNumber.uint32Value)
    }
}
