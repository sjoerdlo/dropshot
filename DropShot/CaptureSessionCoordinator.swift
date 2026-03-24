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

    private struct CaptureRequest: Equatable {
        let id: UInt64
    }

    private enum SessionState {
        case idle
        case capturing(CaptureRequest)
        case presenting(CaptureRequest, CaptureOverlayWindowController)
    }

    typealias StillImageCompletion = (Result<StillImage, Error>) -> Void

    private let permissionCoordinator: PermissionCoordinator
    private let screenCaptureManager: ScreenCaptureManaging
    private var nextCaptureRequestID: UInt64 = 0
    private var sessionState: SessionState = .idle

    var onStillImageReady: ((StillImage) -> Void)?

    init(
        permissionCoordinator: PermissionCoordinator,
        screenCaptureManager: ScreenCaptureManaging = ScreenCaptureManager()
    ) {
        self.permissionCoordinator = permissionCoordinator
        self.screenCaptureManager = screenCaptureManager
    }

    func beginCaptureSession() {
        let request = makeNextCaptureRequest()
        let existingOverlayWindowController = presentedOverlayWindowController

        // Move to the new request before dismissing any older overlay so a close callback
        // from the previous window cannot clear the newer in-flight session.
        sessionState = .capturing(request)
        existingOverlayWindowController?.dismissOverlay()

        captureStillImageForActiveScreen { [weak self] result in
            guard let self else {
                return
            }

            self.handleCaptureResult(result, for: request)
        }
    }

    func dismissCaptureOverlay() {
        guard let overlayWindowController = presentedOverlayWindowController else {
            return
        }

        sessionState = .idle
        overlayWindowController.dismissOverlay()
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

    private var presentedOverlayWindowController: CaptureOverlayWindowController? {
        guard case .presenting(_, let overlayWindowController) = sessionState else {
            return nil
        }

        return overlayWindowController
    }

    private func makeNextCaptureRequest() -> CaptureRequest {
        nextCaptureRequestID += 1
        return CaptureRequest(id: nextCaptureRequestID)
    }

    private func handleCaptureResult(_ result: Result<StillImage, Error>, for request: CaptureRequest) {
        guard case .capturing(let activeRequest) = sessionState, activeRequest == request else {
            logDiscardedCaptureResult(result, for: request)
            return
        }

        switch result {
        case .success(let stillImage):
            presentOverlay(for: stillImage, request: request)

            if let onStillImageReady = onStillImageReady {
                onStillImageReady(stillImage)
            } else {
                NSLog("Presented capture overlay for display \(stillImage.displayID).")
            }
        case .failure(let error):
            sessionState = .idle
            NSLog("Still capture failed: \(error.localizedDescription)")
        }
    }

    private func presentOverlay(for stillImage: StillImage, request: CaptureRequest) {
        let overlayWindowController = CaptureOverlayWindowController(
            screen: stillImage.screen,
            image: stillImage.image
        )
        overlayWindowController.onClose = { [weak self, weak overlayWindowController] in
            guard let self, let overlayWindowController else {
                return
            }

            self.handleOverlayClose(for: request, overlayWindowController: overlayWindowController)
        }

        sessionState = .presenting(request, overlayWindowController)
        overlayWindowController.present()
    }

    private func handleOverlayClose(
        for request: CaptureRequest,
        overlayWindowController: CaptureOverlayWindowController
    ) {
        guard
            case .presenting(let activeRequest, let activeOverlayWindowController) = sessionState,
            activeRequest == request,
            activeOverlayWindowController === overlayWindowController
        else {
            return
        }

        sessionState = .idle
    }

    private func logDiscardedCaptureResult(
        _ result: Result<StillImage, Error>,
        for request: CaptureRequest
    ) {
        switch result {
        case .success(let stillImage):
            NSLog(
                "Discarded stale still capture result for request \(request.id) on display \(stillImage.displayID)."
            )
        case .failure(let error):
            NSLog(
                "Discarded stale still capture failure for request \(request.id): \(error.localizedDescription)"
            )
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

final class CaptureOverlayWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let screen: NSScreen

    init(screen: NSScreen, image: CGImage) {
        self.screen = screen

        let window = CaptureOverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.backgroundColor = .black
        window.isOpaque = true
        window.level = .screenSaver
        window.collectionBehavior = [.fullScreenAuxiliary, .stationary]
        window.animationBehavior = .none

        super.init(window: window)

        window.delegate = self
        window.contentView = Self.makeContentView(for: screen, image: image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else {
            return
        }

        window.setFrame(screen.frame, display: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismissOverlay() {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private static func makeContentView(for screen: NSScreen, image: CGImage) -> NSView {
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(cgImage: image, size: screen.frame.size)
        imageView.imageScaling = .scaleAxesIndependently

        let contentView = NSView(frame: screen.frame)
        contentView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        return contentView
    }
}

private final class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            close()
            return
        }

        super.sendEvent(event)
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
