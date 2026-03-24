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

    private final class PresentationSession {
        let request: CaptureRequest
        let stillImage: StillImage
        let overlayWindowController: CaptureOverlayWindowController
        let controlPanelController: ScrollControlPanelController

        var selectedRegion: SelectedRegion?

        init(
            request: CaptureRequest,
            stillImage: StillImage,
            overlayWindowController: CaptureOverlayWindowController,
            controlPanelController: ScrollControlPanelController
        ) {
            self.request = request
            self.stillImage = stillImage
            self.overlayWindowController = overlayWindowController
            self.controlPanelController = controlPanelController
        }

        func dismissWindows() {
            controlPanelController.dismiss()
            overlayWindowController.dismissOverlay()
        }
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
    var onSessionCancelled: (() -> Void)?
    var onSessionConfirmed: ((SelectedRegion) -> Void)?
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
        let existingPresentationSession = currentPresentationSession

        // Move to the new request before dismissing any older overlay so a close callback
        // from the previous window cannot clear the newer in-flight session.
        selectedRegion = nil
        sessionState = .capturing(request)
        existingPresentationSession?.dismissWindows()

        captureStillImageForActiveScreen { [weak self] result in
            guard let self else {
                return
            }

            self.handleCaptureResult(result, for: request)
        }
    }

    func dismissCaptureOverlay() {
        guard let presentationSession = currentPresentationSession else {
            return
        }

        selectedRegion = nil
        sessionState = .idle
        presentationSession.dismissWindows()
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

    private var currentPresentationSession: PresentationSession? {
        guard case .presenting(let presentationSession) = sessionState else {
            return nil
        }

        return presentationSession
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
        let controlPanelController = ScrollControlPanelController()
        let presentationSession = PresentationSession(
            request: request,
            stillImage: stillImage,
            overlayWindowController: overlayWindowController,
            controlPanelController: controlPanelController
        )

        overlayWindowController.onSelectionFinalized = { [weak self, weak presentationSession] selectedRect in
            guard let self, let presentationSession else {
                return
            }

            self.handleOverlaySelection(selectedRect, for: presentationSession)
        }
        overlayWindowController.onClose = { [weak self, weak presentationSession] in
            guard let self, let presentationSession else {
                return
            }

            self.handleOverlayClose(for: presentationSession)
        }
        controlPanelController.onDone = { [weak self, weak presentationSession] in
            guard let self, let presentationSession else {
                return
            }

            self.handleControlPanelDone(for: presentationSession)
        }
        controlPanelController.onCancel = { [weak self, weak presentationSession] in
            guard let self, let presentationSession else {
                return
            }

            self.handleControlPanelCancel(for: presentationSession)
        }

        sessionState = .presenting(presentationSession)
        overlayWindowController.present()
    }

    private func handleOverlaySelection(
        _ selectedRect: CGRect,
        for presentationSession: PresentationSession
    ) {
        guard
            case .presenting(let activePresentationSession) = sessionState,
            activePresentationSession === presentationSession
        else {
            return
        }

        let selectedRegion = SelectedRegion(
            stillImage: presentationSession.stillImage,
            rect: selectedRect
        )
        presentationSession.selectedRegion = selectedRegion
        self.selectedRegion = selectedRegion
        presentationSession.overlayWindowController.enterPassthroughMode()
        presentationSession.controlPanelController.present(
            anchoredTo: selectedRect,
            on: presentationSession.stillImage.screen
        )

        if let onSelectedRegion {
            onSelectedRegion(selectedRegion)
        } else {
            NSLog(
                "Selected capture rect \(NSStringFromRect(selectedRect)) on display \(presentationSession.stillImage.displayID)."
            )
        }
    }

    private func handleOverlayClose(for presentationSession: PresentationSession) {
        guard
            case .presenting(let activePresentationSession) = sessionState,
            activePresentationSession === presentationSession
        else {
            return
        }

        presentationSession.controlPanelController.dismiss()
        presentationSession.selectedRegion = nil
        selectedRegion = nil
        sessionState = .idle
    }

    private func handleControlPanelCancel(for presentationSession: PresentationSession) {
        guard
            case .presenting(let activePresentationSession) = sessionState,
            activePresentationSession === presentationSession
        else {
            return
        }

        presentationSession.selectedRegion = nil
        selectedRegion = nil
        sessionState = .idle
        presentationSession.dismissWindows()

        if let onSessionCancelled {
            onSessionCancelled()
        } else {
            NSLog("Cancelled capture session for display \(presentationSession.stillImage.displayID).")
        }
    }

    private func handleControlPanelDone(for presentationSession: PresentationSession) {
        guard
            case .presenting(let activePresentationSession) = sessionState,
            activePresentationSession === presentationSession,
            let selectedRegion = presentationSession.selectedRegion
        else {
            return
        }

        self.selectedRegion = nil
        presentationSession.selectedRegion = nil
        sessionState = .idle
        presentationSession.dismissWindows()

        if let onSessionConfirmed {
            onSessionConfirmed(selectedRegion)
        } else {
            NSLog(
                "Done requested for capture rect \(NSStringFromRect(selectedRegion.rect)) on display \(selectedRegion.stillImage.displayID)."
            )
        }
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
