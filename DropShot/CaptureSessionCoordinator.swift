import AppKit
import CoreGraphics
import Foundation

final class CaptureSessionCoordinator {
    struct StillImage {
        let screen: NSScreen
        let displayID: CGDirectDisplayID
        let image: CGImage
    }

    struct SelectedRegion {
        let stillImage: StillImage
        let rect: CGRect
    }

    private struct CaptureRequest: Equatable {
        let id: UInt64
    }

    private struct PresentationSession {
        let request: CaptureRequest
        let stillImage: StillImage
        let overlayWindowController: CaptureOverlayWindowController
    }

    private enum SessionState {
        case idle
        case capturing(CaptureRequest)
        case presenting(PresentationSession)
    }

    typealias StillImageCompletion = (Result<StillImage, Error>) -> Void

    private let permissionCoordinator: PermissionCoordinator
    private let screenCaptureManager: ScreenCaptureManaging
    private var nextCaptureRequestID: UInt64 = 0
    private var sessionState: SessionState = .idle

    var onStillImageReady: ((StillImage) -> Void)?
    var onSelectedRegion: ((SelectedRegion) -> Void)?
    private(set) var selectedRegion: SelectedRegion?

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
        selectedRegion = nil
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

        selectedRegion = nil
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
        guard case .presenting(let presentationSession) = sessionState else {
            return nil
        }

        return presentationSession.overlayWindowController
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
        overlayWindowController.onSelectionFinalized = { [weak self, weak overlayWindowController] selectedRect in
            guard let self, let overlayWindowController else {
                return
            }

            self.handleOverlaySelection(
                selectedRect,
                for: request,
                overlayWindowController: overlayWindowController
            )
        }
        overlayWindowController.onClose = { [weak self, weak overlayWindowController] in
            guard let self, let overlayWindowController else {
                return
            }

            self.handleOverlayClose(for: request, overlayWindowController: overlayWindowController)
        }

        let presentationSession = PresentationSession(
            request: request,
            stillImage: stillImage,
            overlayWindowController: overlayWindowController
        )
        sessionState = .presenting(presentationSession)
        overlayWindowController.present()
    }

    private func handleOverlaySelection(
        _ selectedRect: CGRect,
        for request: CaptureRequest,
        overlayWindowController: CaptureOverlayWindowController
    ) {
        guard
            case .presenting(let presentationSession) = sessionState,
            presentationSession.request == request,
            presentationSession.overlayWindowController === overlayWindowController
        else {
            return
        }

        let selectedRegion = SelectedRegion(
            stillImage: presentationSession.stillImage,
            rect: selectedRect
        )
        self.selectedRegion = selectedRegion

        if let onSelectedRegion {
            onSelectedRegion(selectedRegion)
        } else {
            NSLog(
                "Selected capture rect \(NSStringFromRect(selectedRect)) on display \(presentationSession.stillImage.displayID)."
            )
        }
    }

    private func handleOverlayClose(
        for request: CaptureRequest,
        overlayWindowController: CaptureOverlayWindowController
    ) {
        guard
            case .presenting(let presentationSession) = sessionState,
            presentationSession.request == request,
            presentationSession.overlayWindowController === overlayWindowController
        else {
            return
        }

        selectedRegion = nil
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
