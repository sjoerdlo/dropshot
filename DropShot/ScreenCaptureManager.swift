import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ScreenCaptureKit

struct DisplayCaptureContext {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
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

            guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
                completion(.failure(ScreenCaptureError.screenDisplayUnavailable))
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
                        screenFrame: screen.frame,
                        pointPixelScale: max(
                            screen.backingScaleFactor,
                            pointPixelScale
                        ),
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
        let clippedRect = rect
            .standardized
            .intersection(context.screenFrame)

        guard !clippedRect.isNull, !clippedRect.isEmpty else {
            completion(.failure(ScreenCaptureError.invalidRegionRect(rect: rect)))
            return
        }

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((clippedRect.width * context.pointPixelScale).rounded()))
        configuration.height = max(1, Int((clippedRect.height * context.pointPixelScale).rounded()))
        configuration.showsCursor = false
        configuration.sourceRect = Self.screenCaptureKitSourceRect(
            for: clippedRect,
            within: context.screenFrame
        )
        if #available(macOS 14.0, *) {
            configuration.captureResolution = .best
        }

        let filter = makeContentFilter(using: context)
        Task {
            do {
                guard let image = try await Self.captureSingleFrame(
                    filter: filter,
                    configuration: configuration
                ) else {
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

                completion(.success(Self.copyToCPUBacked(image) ?? image))
            } catch {
                completion(
                    .failure(
                        ScreenCaptureError.regionCaptureFailed(
                            displayID: context.displayID,
                            rect: rect,
                            underlying: error
                        )
                    )
                )
            }
        }
    }

    static func screenCaptureKitSourceRect(
        for globalRect: CGRect,
        within screenFrame: CGRect
    ) -> CGRect {
        let clippedRect = globalRect
            .standardized
            .intersection(screenFrame)
            .standardized

        return CGRect(
            x: clippedRect.minX - screenFrame.minX,
            y: screenFrame.maxY - clippedRect.maxY,
            width: clippedRect.width,
            height: clippedRect.height
        )
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

    private static func captureSingleFrame(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage? {
        let handler = SingleFrameHandler()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(
            handler,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "dropshot.regioncapture")
        )
        try await stream.startCapture()

        let image = await withTaskGroup(of: CGImage?.self) { group -> CGImage? in
            group.addTask {
                await handler.waitForFrame()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return nil
            }

            let firstResult = await group.next() ?? nil
            group.cancelAll()
            return firstResult
        }

        try? await stream.stopCapture()
        return image
    }

    private static func copyToCPUBacked(_ sourceImage: CGImage) -> CGImage? {
        let width = sourceImage.width
        let height = sourceImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

private final class SingleFrameHandler: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var capturedImage: CGImage?
    private var didDeliverFrame = false

    func waitForFrame() async -> CGImage? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didDeliverFrame {
                let image = capturedImage
                lock.unlock()
                continuation.resume(returning: image)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        // Only accept frames with a .complete status.  ScreenCaptureKit may
        // deliver idle, blank, or suspended frames that contain no useful
        // pixel data.  Silently skip those so the next complete frame is used.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusValue = attachments.first?[.status] as? Int,
           SCFrameStatus(rawValue: statusValue) != .complete {
            return
        }

        let image = CIContext().createCGImage(
            CIImage(cvPixelBuffer: pixelBuffer),
            from: CGRect(
                x: 0,
                y: 0,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
        )

        lock.lock()
        guard !didDeliverFrame else {
            lock.unlock()
            return
        }

        didDeliverFrame = true
        capturedImage = image
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: image)
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
