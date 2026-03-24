import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct DisplayCaptureContext {
    let displayID: CGDirectDisplayID
    let displayFrame: CGRect
    let pointPixelScale: CGFloat

    fileprivate let display: SCDisplay
    fileprivate let excludedApplications: [SCRunningApplication]
    fileprivate let excludedWindows: [SCWindow]
}

protocol ScreenCaptureManaging {
    func captureStillImage(
        for displayID: CGDirectDisplayID,
        completion: @escaping (Result<CGImage, Error>) -> Void
    )

    func prepareRegionCapture(
        for displayID: CGDirectDisplayID,
        excludingProcessID: pid_t,
        excludingBundleIdentifier: String?,
        completion: @escaping (Result<DisplayCaptureContext, Error>) -> Void
    )

    func captureRegionImage(
        using context: DisplayCaptureContext,
        rect: CGRect,
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

    func prepareRegionCapture(
        for displayID: CGDirectDisplayID,
        excludingProcessID: pid_t,
        excludingBundleIdentifier: String?,
        completion: @escaping (Result<DisplayCaptureContext, Error>) -> Void
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

            let excludedApplications = shareableContent.applications.filter { application in
                if application.processID == excludingProcessID {
                    return true
                }

                guard let excludingBundleIdentifier else {
                    return false
                }

                return application.bundleIdentifier == excludingBundleIdentifier
            }
            let excludedWindows = shareableContent.windows.filter { window in
                guard let owningApplication = window.owningApplication else {
                    return false
                }

                if owningApplication.processID == excludingProcessID {
                    return true
                }

                guard let excludingBundleIdentifier else {
                    return false
                }

                return owningApplication.bundleIdentifier == excludingBundleIdentifier
            }
            let pointPixelScale = CGFloat(displayMode.pixelWidth) / max(CGFloat(display.width), 1)

            completion(
                .success(
                    DisplayCaptureContext(
                        displayID: displayID,
                        displayFrame: display.frame,
                        pointPixelScale: pointPixelScale,
                        display: display,
                        excludedApplications: excludedApplications,
                        excludedWindows: excludedWindows
                    )
                )
            )
        }
    }

    func captureRegionImage(
        using context: DisplayCaptureContext,
        rect: CGRect,
        completion: @escaping (Result<CGImage, Error>) -> Void
    ) {
        guard !rect.isNull, !rect.isEmpty else {
            completion(.failure(ScreenCaptureError.invalidRegionRect(rect: rect)))
            return
        }

        let localRect = rect
            .offsetBy(dx: -context.displayFrame.minX, dy: -context.displayFrame.minY)
            .standardized
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((localRect.width * context.pointPixelScale).rounded()))
        configuration.height = max(1, Int((localRect.height * context.pointPixelScale).rounded()))
        configuration.showsCursor = false
        configuration.sourceRect = localRect

        let filter = makeContentFilter(using: context)
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
            if let error {
                completion(
                    .failure(
                        ScreenCaptureError.regionCaptureFailed(
                            displayID: context.displayID,
                            rect: rect,
                            underlying: error
                        )
                    )
                )
                return
            }

            guard let image else {
                completion(
                    .failure(
                        ScreenCaptureError.regionImageUnavailable(
                            displayID: context.displayID,
                            rect: rect
                        )
                    )
                )
                return
            }

            completion(.success(image))
        }
    }

    private func makeContentFilter(using context: DisplayCaptureContext) -> SCContentFilter {
        if !context.excludedApplications.isEmpty {
            return SCContentFilter(
                display: context.display,
                excludingApplications: context.excludedApplications,
                exceptingWindows: []
            )
        }

        return SCContentFilter(display: context.display, excludingWindows: context.excludedWindows)
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
    case invalidRegionRect(rect: CGRect)
    case regionCaptureFailed(displayID: CGDirectDisplayID, rect: CGRect, underlying: Error)
    case regionImageUnavailable(displayID: CGDirectDisplayID, rect: CGRect)

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
        case .invalidRegionRect(let rect):
            return "Cannot capture an empty region rect \(NSStringFromRect(rect))."
        case .regionCaptureFailed(let displayID, let rect, let underlying):
            return
                "Region capture failed for display \(displayID) at \(NSStringFromRect(rect)): \(underlying.localizedDescription)"
        case .regionImageUnavailable(let displayID, let rect):
            return
                "Region capture for display \(displayID) at \(NSStringFromRect(rect)) completed without an image."
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
