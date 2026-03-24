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
        let scrollCaptureController: ScrollCaptureController

        var selectedRegion: SelectedRegion?

        init(
            request: CaptureRequest,
            stillImage: StillImage,
            overlayWindowController: CaptureOverlayWindowController,
            controlPanelController: ScrollControlPanelController,
            scrollCaptureController: ScrollCaptureController
        ) {
            self.request = request
            self.stillImage = stillImage
            self.overlayWindowController = overlayWindowController
            self.controlPanelController = controlPanelController
            self.scrollCaptureController = scrollCaptureController
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
    var onScrollCaptureSessionCompleted: ((ScrollCaptureController.CompletedSession) -> Void)?
    private(set) var selectedRegion: SelectedRegion?
    private(set) var lastCompletedScrollCaptureSession: ScrollCaptureController.CompletedSession?

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
        lastCompletedScrollCaptureSession = nil
        sessionState = .capturing(request)
        existingPresentationSession?.scrollCaptureController.cancelSession()
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
        presentationSession.scrollCaptureController.cancelSession()
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
        let scrollCaptureController = ScrollCaptureController(screenCaptureManager: screenCaptureManager)
        let presentationSession = PresentationSession(
            request: request,
            stillImage: stillImage,
            overlayWindowController: overlayWindowController,
            controlPanelController: controlPanelController,
            scrollCaptureController: scrollCaptureController
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
        scrollCaptureController.onEscapePressed = { [weak self, weak presentationSession] in
            guard let self, let presentationSession else {
                return
            }

            self.handleEscapeRequest(for: presentationSession)
        }
        scrollCaptureController.onFailure = { [weak self, weak presentationSession] error in
            guard let self, let presentationSession else {
                return
            }

            self.handleScrollCaptureFailure(error, for: presentationSession)
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
        presentationSession.scrollCaptureController.startSession(for: selectedRegion) {
            [weak self, weak presentationSession] result in
            guard let self, let presentationSession else {
                return
            }

            self.handleScrollCaptureStart(
                result,
                selectedRect: selectedRect,
                selectedRegion: selectedRegion,
                for: presentationSession
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

        cancelPresentationSession(presentationSession)
    }

    private func handleControlPanelCancel(for presentationSession: PresentationSession) {
        guard
            case .presenting(let activePresentationSession) = sessionState,
            activePresentationSession === presentationSession
        else {
            return
        }

        cancelPresentationSession(presentationSession)
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
        presentationSession.scrollCaptureController.finishSession { [weak self, weak presentationSession] result in
            guard let self, let presentationSession else {
                return
            }

            self.handleFinishedScrollCapture(
                result,
                selectedRegion: selectedRegion,
                for: presentationSession
            )
        }
    }

    private func handleScrollCaptureStart(
        _ result: Result<Void, Error>,
        selectedRect: CGRect,
        selectedRegion: SelectedRegion,
        for presentationSession: PresentationSession
    ) {
        guard
            case .presenting(let activePresentationSession) = sessionState,
            activePresentationSession === presentationSession
        else {
            return
        }

        switch result {
        case .success:
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
        case .failure(let error):
            if isCancelledScrollCaptureError(error) {
                return
            }

            handleScrollCaptureFailure(error, for: presentationSession)
        }
    }

    private func handleFinishedScrollCapture(
        _ result: Result<ScrollCaptureController.CompletedSession, Error>,
        selectedRegion: SelectedRegion,
        for presentationSession: PresentationSession
    ) {
        guard
            case .presenting(let activePresentationSession) = sessionState,
            activePresentationSession === presentationSession
        else {
            return
        }

        switch result {
        case .success(let completedSession):
            sessionState = .idle
            presentationSession.dismissWindows()
            lastCompletedScrollCaptureSession = completedSession

            if let onScrollCaptureSessionCompleted {
                onScrollCaptureSessionCompleted(completedSession)
            } else {
                let compositeSize = completedSession.composite.metadata.compositePixelSize
                NSLog(
                    "Stitched \(completedSession.composite.metadata.sourceStripCount) strips into a \(Int(compositeSize.width))x\(Int(compositeSize.height)) composite for capture rect \(NSStringFromRect(selectedRegion.rect)) on display \(selectedRegion.stillImage.displayID)."
                )
            }

            if let onSessionConfirmed {
                onSessionConfirmed(selectedRegion)
            } else {
                NSLog(
                    "Done requested for capture rect \(NSStringFromRect(selectedRegion.rect)) on display \(selectedRegion.stillImage.displayID)."
                )
            }
        case .failure(let error):
            handleScrollCaptureFailure(error, for: presentationSession)
        }
    }

    private func handleEscapeRequest(for presentationSession: PresentationSession) {
        guard
            case .presenting(let activePresentationSession) = sessionState,
            activePresentationSession === presentationSession
        else {
            return
        }

        cancelPresentationSession(presentationSession)
    }

    private func handleScrollCaptureFailure(_ error: Error, for presentationSession: PresentationSession) {
        guard
            case .presenting(let activePresentationSession) = sessionState,
            activePresentationSession === presentationSession
        else {
            return
        }

        NSLog("Scroll capture failed: \(error.localizedDescription)")
        cancelPresentationSession(presentationSession)
    }

    private func cancelPresentationSession(_ presentationSession: PresentationSession) {
        presentationSession.selectedRegion = nil
        selectedRegion = nil
        sessionState = .idle
        presentationSession.scrollCaptureController.cancelSession()
        presentationSession.dismissWindows()

        if let onSessionCancelled {
            onSessionCancelled()
        } else {
            NSLog("Cancelled capture session for display \(presentationSession.stillImage.displayID).")
        }
    }

    private func isCancelledScrollCaptureError(_ error: Error) -> Bool {
        guard let scrollCaptureError = error as? ScrollCaptureController.ScrollCaptureError else {
            return false
        }

        return scrollCaptureError == .cancelled
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
