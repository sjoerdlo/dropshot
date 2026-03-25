import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

final class ScrollCaptureController {
    struct Region {
        let displayID: CGDirectDisplayID
        let displayFrame: CGRect
        let rect: CGRect

        init(selectedRegion: CaptureSessionCoordinator.SelectedRegion) {
            displayID = selectedRegion.stillImage.displayID
            displayFrame = selectedRegion.stillImage.screen.frame
            rect = selectedRegion.rect
        }
    }

    struct Strip {
        let index: Int
        let image: CGImage
        let rect: CGRect
        let capturedAt: Date
    }

    struct CompletedSession {
        let region: Region
        let composite: StitchingEngine.Composite
        let startedAt: Date
        let endedAt: Date
    }

    enum ScrollCaptureError: LocalizedError, Equatable {
        case sessionAlreadyRunning
        case noActiveSession
        case cancelled
        case noCapturedStrips

        var errorDescription: String? {
            switch self {
            case .sessionAlreadyRunning:
                return "A scroll capture session is already running."
            case .noActiveSession:
                return "No scroll capture session is active."
            case .cancelled:
                return "The scroll capture session was cancelled."
            case .noCapturedStrips:
                return "The scroll capture session finished without any captured strips."
            }
        }
    }

    var onStripCaptured: ((Strip) -> Void)?
    var onEscapePressed: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    private enum Phase: Equatable {
        case starting
        case active
        case finishing
        case cancelling
    }

    private final class ActiveSession {
        let region: Region
        let startedAt = Date()
        let stitchingEngine: StitchingEngine

        var phase: Phase = .starting
        var captureContext: DisplayCaptureContext?
        var nextStripIndex = 0
        var lastCapturedAt: Date?
        var isCaptureInFlight = false
        var hasDeferredCaptureRequest = false
        var wantsFinalCaptureBeforeFinish = false
        var didRequestEscapeTermination = false
        var pendingScrollCaptureWorkItem: DispatchWorkItem?
        var globalScrollMonitor: Any?
        var localScrollMonitor: Any?
        var localKeyMonitor: Any?
        var startCompletion: ((Result<Void, Error>) -> Void)?
        var finishCompletion: ((Result<CompletedSession, Error>) -> Void)?
        var cancelCompletion: ((Result<Void, Error>) -> Void)?

        init(region: Region, stitchingEngine: StitchingEngine) {
            self.region = region
            self.stitchingEngine = stitchingEngine
        }
    }

    private let screenCaptureManager: ScreenCaptureManaging
    private let stitchingEngineFactory: () -> StitchingEngine
    private let captureSettleDelay: TimeInterval = 0.08
    private let captureThrottleInterval: TimeInterval = 0.10
    private let escapeHotKeyMonitor = EscapeHotKeyMonitor()

    private var activeSession: ActiveSession?

    init(
        screenCaptureManager: ScreenCaptureManaging = ScreenCaptureManager(),
        stitchingEngineFactory: @escaping () -> StitchingEngine = { StitchingEngine() }
    ) {
        self.screenCaptureManager = screenCaptureManager
        self.stitchingEngineFactory = stitchingEngineFactory
    }

    deinit {
        escapeHotKeyMonitor.unregister()
    }

    func startSession(
        for selectedRegion: CaptureSessionCoordinator.SelectedRegion,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if Thread.isMainThread {
            startSessionOnMain(for: selectedRegion, completion: completion)
        } else {
            DispatchQueue.main.async {
                self.startSessionOnMain(for: selectedRegion, completion: completion)
            }
        }
    }

    func finishSession(completion: @escaping (Result<CompletedSession, Error>) -> Void) {
        if Thread.isMainThread {
            finishSessionOnMain(completion: completion)
        } else {
            DispatchQueue.main.async {
                self.finishSessionOnMain(completion: completion)
            }
        }
    }

    func cancelSession(completion: ((Result<Void, Error>) -> Void)? = nil) {
        if Thread.isMainThread {
            cancelSessionOnMain(completion: completion)
        } else {
            DispatchQueue.main.async {
                self.cancelSessionOnMain(completion: completion)
            }
        }
    }

    private func startSessionOnMain(
        for selectedRegion: CaptureSessionCoordinator.SelectedRegion,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard activeSession == nil else {
            completion(.failure(ScrollCaptureError.sessionAlreadyRunning))
            return
        }

        let session = ActiveSession(
            region: Region(selectedRegion: selectedRegion),
            stitchingEngine: stitchingEngineFactory()
        )
        session.startCompletion = completion
        activeSession = session

        screenCaptureManager.prepareRegionCapture(
            for: session.region.displayID,
            excludingProcessID: ProcessInfo.processInfo.processIdentifier,
            excludingBundleIdentifier: Bundle.main.bundleIdentifier
        ) { [weak self, weak session] result in
            DispatchQueue.main.async {
                guard let self, let session else {
                    return
                }

                self.handlePreparedCaptureContext(result, for: session)
            }
        }
    }

    private func finishSessionOnMain(completion: @escaping (Result<CompletedSession, Error>) -> Void) {
        guard let session = activeSession else {
            completion(.failure(ScrollCaptureError.noActiveSession))
            return
        }

        switch session.phase {
        case .starting, .active:
            removeEventMonitors(from: session)

            let wantsFinalCapture = session.pendingScrollCaptureWorkItem != nil || session.hasDeferredCaptureRequest
            session.pendingScrollCaptureWorkItem?.cancel()
            session.pendingScrollCaptureWorkItem = nil
            session.hasDeferredCaptureRequest = false
            session.phase = .finishing
            session.finishCompletion = completion
            session.wantsFinalCaptureBeforeFinish = wantsFinalCapture && session.captureContext != nil

            if session.isCaptureInFlight {
                return
            }

            if session.wantsFinalCaptureBeforeFinish {
                session.wantsFinalCaptureBeforeFinish = false
                captureStrip(in: session)
            } else {
                finalizeFinishedSession(session)
            }
        case .finishing:
            session.finishCompletion = completion
        case .cancelling:
            completion(.failure(ScrollCaptureError.noActiveSession))
        }
    }

    private func cancelSessionOnMain(completion: ((Result<Void, Error>) -> Void)?) {
        guard let session = activeSession else {
            completion?(.success(()))
            return
        }

        switch session.phase {
        case .cancelling:
            completion?(.success(()))
        case .starting, .active, .finishing:
            removeEventMonitors(from: session)
            session.pendingScrollCaptureWorkItem?.cancel()
            session.pendingScrollCaptureWorkItem = nil
            session.hasDeferredCaptureRequest = false
            session.wantsFinalCaptureBeforeFinish = false
            session.phase = .cancelling
            session.cancelCompletion = completion

            if let startCompletion = session.startCompletion {
                session.startCompletion = nil
                startCompletion(.failure(ScrollCaptureError.cancelled))
            }

            session.finishCompletion = nil

            if session.isCaptureInFlight {
                return
            }

            finalizeCancelledSession(session)
        }
    }

    private func handlePreparedCaptureContext(
        _ result: Result<DisplayCaptureContext, Error>,
        for session: ActiveSession
    ) {
        guard activeSession === session else {
            return
        }

        switch result {
        case .success(let context):
            session.captureContext = context

            guard session.phase != .cancelling else {
                finalizeCancelledSession(session)
                return
            }

            captureStrip(in: session)
        case .failure(let error):
            guard session.phase != .cancelling else {
                finalizeCancelledSession(session)
                return
            }

            failSession(session, with: error)
        }
    }

    private func handleScrollEvent(_ event: NSEvent, for session: ActiveSession) {
        guard activeSession === session, session.phase == .active else {
            return
        }

        let deltaY = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
        guard deltaY != 0 else {
            return
        }

        guard isPointerInsideSelectedRegion(session.region) else {
            return
        }

        scheduleScrollDrivenCapture(for: session)
    }

    private func handleEscapeKey(for session: ActiveSession) {
        guard activeSession === session, session.phase == .active, !session.didRequestEscapeTermination else {
            return
        }

        session.didRequestEscapeTermination = true
        onEscapePressed?()
    }

    private func captureStrip(in session: ActiveSession) {
        guard activeSession === session else {
            return
        }

        guard let captureContext = session.captureContext else {
            failSession(session, with: ScrollCaptureError.noActiveSession)
            return
        }

        if session.isCaptureInFlight {
            session.hasDeferredCaptureRequest = true
            return
        }

        session.isCaptureInFlight = true
        screenCaptureManager.captureRegionImage(using: captureContext, rect: session.region.rect) { [weak self, weak session] result in
            DispatchQueue.main.async {
                guard let self, let session else {
                    return
                }

                self.handleCapturedStrip(result, for: session)
            }
        }
    }

    private func handleCapturedStrip(_ result: Result<CGImage, Error>, for session: ActiveSession) {
        guard activeSession === session else {
            return
        }

        session.isCaptureInFlight = false

        switch result {
        case .success(let image):
            if session.phase == .cancelling {
                finalizeCancelledSession(session)
                return
            }

            let capturedAt = Date()
            let strip = Strip(
                index: session.nextStripIndex,
                image: image,
                rect: session.region.rect,
                capturedAt: capturedAt
            )
            session.nextStripIndex += 1
            session.lastCapturedAt = capturedAt

            do {
                try session.stitchingEngine.addStrip(
                    StitchingEngine.Strip(
                        index: strip.index,
                        image: image,
                        capturedAt: capturedAt
                    )
                )
            } catch {
                failSession(session, with: error)
                return
            }

            onStripCaptured?(strip)
            advanceSessionAfterSuccessfulCapture(session)
        case .failure(let error):
            if session.phase == .cancelling {
                finalizeCancelledSession(session)
                return
            }

            failSession(session, with: error)
        }
    }

    private func advanceSessionAfterSuccessfulCapture(_ session: ActiveSession) {
        switch session.phase {
        case .starting:
            installEventMonitors(for: session)
            session.phase = .active

            let completion = session.startCompletion
            session.startCompletion = nil
            completion?(.success(()))
        case .active:
            if session.hasDeferredCaptureRequest {
                session.hasDeferredCaptureRequest = false
                scheduleScrollDrivenCapture(for: session)
            }
        case .finishing:
            if session.wantsFinalCaptureBeforeFinish {
                session.wantsFinalCaptureBeforeFinish = false
                captureStrip(in: session)
            } else {
                finalizeFinishedSession(session)
            }
        case .cancelling:
            finalizeCancelledSession(session)
        }
    }

    private func scheduleScrollDrivenCapture(for session: ActiveSession) {
        guard activeSession === session, session.phase == .active else {
            return
        }

        let now = Date()
        let nextAllowedCaptureAt = session.lastCapturedAt?.addingTimeInterval(captureThrottleInterval) ?? now

        // If the throttle interval has already elapsed, capture immediately
        // instead of waiting for the settle delay.  This ensures we grab
        // frames *during* a fast scroll, not just after it stops.
        if now >= nextAllowedCaptureAt && session.pendingScrollCaptureWorkItem == nil {
            captureStrip(in: session)
            return
        }

        // If a throttle-triggered capture is already scheduled, leave it
        // alone — don't cancel and re-delay.  Only schedule a new work
        // item when nothing is pending.
        guard session.pendingScrollCaptureWorkItem == nil else {
            return
        }

        let scheduledCaptureAt = max(now.addingTimeInterval(captureSettleDelay), nextAllowedCaptureAt)
        let delay = max(0, scheduledCaptureAt.timeIntervalSinceNow)
        let workItem = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, self.activeSession === session else {
                return
            }

            session.pendingScrollCaptureWorkItem = nil
            self.captureStrip(in: session)
        }

        session.pendingScrollCaptureWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func installEventMonitors(for session: ActiveSession) {
        session.globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self, weak session] event in
            DispatchQueue.main.async {
                guard let self, let session else {
                    return
                }

                self.handleScrollEvent(event, for: session)
            }
        }
        session.localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak session] event in
            guard let self, let session else {
                return event
            }

            self.handleScrollEvent(event, for: session)
            return event
        }
        // `Esc` must keep working after focus returns to the app being scrolled.
        // A registered hot key does not depend on Accessibility trust the way AppKit's
        // global key monitor does.
        escapeHotKeyMonitor.register { [weak self, weak session] in
            guard let self, let session else {
                return
            }

            self.handleEscapeKey(for: session)
        }
        session.localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak session] event in
            guard let self, let session else {
                return event
            }

            guard event.keyCode == 53 else {
                return event
            }

            self.handleEscapeKey(for: session)
            return nil
        }
    }

    private func removeEventMonitors(from session: ActiveSession) {
        if let globalScrollMonitor = session.globalScrollMonitor {
            NSEvent.removeMonitor(globalScrollMonitor)
            session.globalScrollMonitor = nil
        }

        if let localScrollMonitor = session.localScrollMonitor {
            NSEvent.removeMonitor(localScrollMonitor)
            session.localScrollMonitor = nil
        }

        if let localKeyMonitor = session.localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            session.localKeyMonitor = nil
        }

        escapeHotKeyMonitor.unregister()
    }

    private func finalizeFinishedSession(_ session: ActiveSession) {
        guard activeSession === session else {
            return
        }

        session.pendingScrollCaptureWorkItem?.cancel()
        session.pendingScrollCaptureWorkItem = nil
        removeEventMonitors(from: session)
        activeSession = nil

        let completion = session.finishCompletion
        session.finishCompletion = nil

        guard session.nextStripIndex > 0 else {
            completion?(.failure(ScrollCaptureError.noCapturedStrips))
            return
        }

        let composite: StitchingEngine.Composite
        do {
            composite = try session.stitchingEngine.buildComposite()
        } catch {
            completion?(.failure(error))
            return
        }

        completion?(
            .success(
                CompletedSession(
                    region: session.region,
                    composite: composite,
                    startedAt: session.startedAt,
                    endedAt: Date()
                )
            )
        )
    }

    private func finalizeCancelledSession(_ session: ActiveSession) {
        guard activeSession === session else {
            return
        }

        session.pendingScrollCaptureWorkItem?.cancel()
        session.pendingScrollCaptureWorkItem = nil
        removeEventMonitors(from: session)
        activeSession = nil

        let completion = session.cancelCompletion
        session.cancelCompletion = nil
        completion?(.success(()))
    }

    private func failSession(_ session: ActiveSession, with error: Error) {
        guard activeSession === session else {
            return
        }

        let shouldReportFailure = session.phase == .active
        session.pendingScrollCaptureWorkItem?.cancel()
        session.pendingScrollCaptureWorkItem = nil
        removeEventMonitors(from: session)
        activeSession = nil

        if let startCompletion = session.startCompletion {
            session.startCompletion = nil
            startCompletion(.failure(error))
            return
        }

        if let finishCompletion = session.finishCompletion {
            session.finishCompletion = nil
            finishCompletion(.failure(error))
            return
        }

        if let cancelCompletion = session.cancelCompletion {
            session.cancelCompletion = nil
            cancelCompletion(.failure(error))
            return
        }

        if shouldReportFailure {
            onFailure?(error)
        }
    }

    private func isPointerInsideSelectedRegion(_ region: Region) -> Bool {
        region.rect.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
    }
}

private final class EscapeHotKeyMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onEscapePressed: (() -> Void)?

    func register(onEscapePressed: @escaping () -> Void) {
        self.onEscapePressed = onEscapePressed

        guard hotKeyRef == nil, eventHandlerRef == nil else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyEventHandler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )

        guard handlerStatus == noErr else {
            NSLog("Failed to install live scroll escape hotkey handler: %d", handlerStatus)
            return
        }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyIdentifier)
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registrationStatus == noErr else {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                self.eventHandlerRef = nil
            }

            NSLog("Failed to register live scroll escape hotkey: %d", registrationStatus)
            return
        }
    }

    func unregister() {
        onEscapePressed = nil

        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    deinit {
        unregister()
    }

    private func handleHotKeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event else {
            return noErr
        }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else {
            return status
        }

        guard hotKeyID.signature == Self.hotKeySignature, hotKeyID.id == Self.hotKeyIdentifier else {
            return noErr
        }

        let onEscapePressed = self.onEscapePressed
        DispatchQueue.main.async(execute: onEscapePressed ?? {})
        return noErr
    }

    private static let hotKeySignature = fourCharacterCode("DSES")
    private static let hotKeyIdentifier: UInt32 = 1
    private static let hotKeyEventHandler: EventHandlerUPP = { _, event, userData in
        guard let userData else {
            return noErr
        }

        let monitor = Unmanaged<EscapeHotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
        return monitor.handleHotKeyEvent(event)
    }

    private static func fourCharacterCode(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
