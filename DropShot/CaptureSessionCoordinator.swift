import AppKit
import CoreGraphics
import Foundation

protocol CaptureOverlayPresenting: AnyObject {
    var onClose: (() -> Void)? { get set }
    var onSelectionFinalized: ((CGRect) -> Void)? { get set }
    var selectedRect: CGRect? { get }

    func present()
    func dismissOverlay()
    func enterPassthroughMode()
}

protocol ScrollControlPanelPresenting: AnyObject {
    var onDone: (() -> Void)? { get set }
    var onCancel: (() -> Void)? { get set }

    func present(anchoredTo selectionRect: CGRect, on screen: NSScreen)
    func dismiss()
}

protocol ScrollCaptureSessionControlling: AnyObject {
    var onEscapePressed: (() -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }

    func startSession(
        for selectedRegion: CaptureSessionCoordinator.SelectedRegion,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func finishSession(
        completion: @escaping (Result<ScrollCaptureController.CompletedSession, Error>) -> Void
    )
    func cancelSession(completion: ((Result<Void, Error>) -> Void)?)
}

protocol ResultWindowPresenting: AnyObject {
    var onClose: (() -> Void)? { get set }

    func present()
    func close()
}

final class CaptureSessionCoordinator {
    struct StillImage {
        let screen: NSScreen
        let displayID: CGDirectDisplayID
        let image: CGImage

        var pointPixelScale: CGFloat {
            let screenSize = screen.frame.size
            let widthScale = CGFloat(image.width) / max(screenSize.width, 1)
            let heightScale = CGFloat(image.height) / max(screenSize.height, 1)
            let resolvedScale = max(widthScale, heightScale)
            return resolvedScale.isFinite && resolvedScale > 0 ? resolvedScale : 1
        }

        func pointSize(for pixelSize: CGSize) -> CGSize {
            let scale = pointPixelScale
            return CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        }
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
        let overlayWindowController: CaptureOverlayPresenting
        let controlPanelController: ScrollControlPanelPresenting
        let scrollCaptureController: ScrollCaptureSessionControlling

        var selectedRegion: SelectedRegion?

        init(
            request: CaptureRequest,
            stillImage: StillImage,
            overlayWindowController: CaptureOverlayPresenting,
            controlPanelController: ScrollControlPanelPresenting,
            scrollCaptureController: ScrollCaptureSessionControlling
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
    typealias StillImageCaptureHandler = (@escaping StillImageCompletion) -> Void

    private let permissionCoordinator: PermissionCoordinator
    private let screenCaptureManager: ScreenCaptureManaging
    private let stillImageCaptureOverride: StillImageCaptureHandler?
    private let overlayFactory: (StillImage) -> CaptureOverlayPresenting
    private let controlPanelFactory: () -> ScrollControlPanelPresenting
    private let scrollCaptureFactory: () -> ScrollCaptureSessionControlling
    private let resultWindowFactory: (CGImage, CGSize, NSScreen?, String) -> ResultWindowPresenting
    private var nextCaptureRequestID: UInt64 = 0
    private var sessionState: SessionState = .idle
    private var resultWindowController: ResultWindowPresenting?

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
        stillImageCaptureOverride = nil
        overlayFactory = { stillImage in
            CaptureOverlayWindowController(screen: stillImage.screen, image: stillImage.image)
        }
        controlPanelFactory = { ScrollControlPanelController() }
        scrollCaptureFactory = { ScrollCaptureController(screenCaptureManager: screenCaptureManager) }
        resultWindowFactory = { image, pointSize, preferredScreen, defaultFileName in
            ResultWindowController(
                image: image,
                pointSize: pointSize,
                preferredScreen: preferredScreen,
                defaultFileName: defaultFileName
            )
        }
    }

    init(
        permissionCoordinator: PermissionCoordinator = PermissionCoordinator(),
        screenCaptureManager: ScreenCaptureManaging = ScreenCaptureManager(),
        stillImageCaptureOverride: StillImageCaptureHandler? = nil,
        overlayFactory: @escaping (StillImage) -> CaptureOverlayPresenting,
        controlPanelFactory: @escaping () -> ScrollControlPanelPresenting,
        scrollCaptureFactory: @escaping () -> ScrollCaptureSessionControlling,
        resultWindowFactory: @escaping (CGImage, CGSize, NSScreen?, String) -> ResultWindowPresenting
    ) {
        self.permissionCoordinator = permissionCoordinator
        self.screenCaptureManager = screenCaptureManager
        self.stillImageCaptureOverride = stillImageCaptureOverride
        self.overlayFactory = overlayFactory
        self.controlPanelFactory = controlPanelFactory
        self.scrollCaptureFactory = scrollCaptureFactory
        self.resultWindowFactory = resultWindowFactory
    }

    func beginCaptureSession() {
        let request = makeNextCaptureRequest()
        let existingPresentationSession = currentPresentationSession

        // Move to the new request before dismissing any older overlay so a close callback
        // from the previous window cannot clear the newer in-flight session.
        selectedRegion = nil
        lastCompletedScrollCaptureSession = nil
        sessionState = .capturing(request)
        resultWindowController?.close()
        resultWindowController = nil
        existingPresentationSession?.scrollCaptureController.cancelSession(completion: nil)
        existingPresentationSession?.dismissWindows()

        let captureStillImage = stillImageCaptureOverride ?? captureStillImageForActiveScreen
        captureStillImage { [weak self] result in
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
        presentationSession.scrollCaptureController.cancelSession(completion: nil)
        presentationSession.dismissWindows()
    }

    func captureStillImageForActiveScreen(completion: @escaping StillImageCompletion) {
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

        screenCaptureManager.captureStillImage(for: displayID) { [screen, weak self] result in
            guard let self else {
                return
            }

            switch result {
            case .success(let image):
                self.complete(
                    completion,
                    with: .success(StillImage(screen: screen, displayID: displayID, image: image))
                )
            case .failure(let error):
                guard !self.permissionCoordinator.hasScreenRecordingPermission else {
                    self.complete(completion, with: .failure(error))
                    return
                }

                DispatchQueue.main.async {
                    _ = self.permissionCoordinator.ensureScreenRecordingPermission()
                }
                self.complete(completion, with: .failure(ScreenCaptureError.permissionRequired))
            }
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
        let overlayWindowController = overlayFactory(stillImage)
        let controlPanelController = controlPanelFactory()
        let scrollCaptureController = scrollCaptureFactory()
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
            presentResultWindow(for: completedSession, selectedRegion: selectedRegion)

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
        presentationSession.scrollCaptureController.cancelSession(completion: nil)
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

    private func presentResultWindow(
        for completedSession: ScrollCaptureController.CompletedSession,
        selectedRegion: SelectedRegion
    ) {
        resultWindowController?.close()

        let pointSize = selectedRegion.stillImage.pointSize(
            for: completedSession.composite.metadata.compositePixelSize
        )

        let windowController = resultWindowFactory(
            completedSession.composite.image,
            pointSize,
            selectedRegion.stillImage.screen,
            ResultWindowController.defaultFileName(for: completedSession.endedAt)
        )
        windowController.onClose = { [weak self, weak windowController] in
            guard let self else {
                return
            }

            if self.resultWindowController === windowController {
                self.resultWindowController = nil
            }
        }

        resultWindowController = windowController
        windowController.present()
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

extension CaptureOverlayWindowController: CaptureOverlayPresenting {}

extension ScrollControlPanelController: ScrollControlPanelPresenting {}

extension ScrollCaptureController: ScrollCaptureSessionControlling {}

extension ResultWindowController: ResultWindowPresenting {}
