import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import DropShot

@MainActor
final class CaptureSessionCoordinatorTests: XCTestCase {
    func testDonePresentsResultAndDismissesTransientSessionUI() throws {
        let harness = try makeHarness()
        let expectedResultFileName = ResultWindowController.defaultFileName(
            for: harness.completedSession.endedAt
        )

        var confirmedRegions: [CaptureSessionCoordinator.SelectedRegion] = []
        var completedSessions: [ScrollCaptureController.CompletedSession] = []
        var cancelledCount = 0

        harness.coordinator.onSessionConfirmed = { confirmedRegions.append($0) }
        harness.coordinator.onScrollCaptureSessionCompleted = { completedSessions.append($0) }
        harness.coordinator.onSessionCancelled = { cancelledCount += 1 }

        harness.coordinator.beginCaptureSession()
        XCTAssertEqual(harness.overlay.presentCount, 1)

        harness.overlay.triggerSelection(harness.selectionRect)

        XCTAssertEqual(harness.overlay.enterPassthroughModeCount, 1)
        XCTAssertEqual(harness.controlPanel.presentCount, 1)
        XCTAssertEqual(harness.controlPanel.lastPresentedRect, harness.selectionRect)
        XCTAssertEqual(harness.scrollCapture.startCallCount, 1)
        XCTAssertEqual(harness.scrollCapture.lastStartedRegion?.rect, harness.selectionRect)
        XCTAssertEqual(harness.coordinator.selectedRegion?.rect, harness.selectionRect)

        harness.controlPanel.triggerDone()

        XCTAssertEqual(harness.scrollCapture.finishCallCount, 1)
        XCTAssertEqual(harness.scrollCapture.cancelCallCount, 0)
        XCTAssertEqual(harness.overlay.dismissCount, 1)
        XCTAssertEqual(harness.controlPanel.dismissCount, 1)
        XCTAssertNil(harness.coordinator.selectedRegion)
        XCTAssertEqual(
            harness.coordinator.lastCompletedScrollCaptureSession?.endedAt,
            harness.completedSession.endedAt
        )
        XCTAssertEqual(confirmedRegions.map(\.rect), [harness.selectionRect])
        XCTAssertEqual(completedSessions.count, 1)
        XCTAssertEqual(cancelledCount, 0)

        XCTAssertEqual(harness.resultWindowFactory.createdWindows.count, 1)
        let resultWindow = try XCTUnwrap(harness.resultWindowFactory.createdWindows.first)
        XCTAssertEqual(resultWindow.presentCount, 1)
        XCTAssertEqual(resultWindow.closeCount, 0)
        XCTAssertEqual(resultWindow.preferredScreen, harness.stillImage.screen)
        XCTAssertEqual(resultWindow.defaultFileName, expectedResultFileName)
        XCTAssertEqual(resultWindow.image.width, harness.completedSession.composite.image.width)
        XCTAssertEqual(resultWindow.image.height, harness.completedSession.composite.image.height)
        XCTAssertEqual(
            resultWindow.pointSize.width,
            harness.stillImage.pointSize(
                for: harness.completedSession.composite.metadata.compositePixelSize
            ).width,
            accuracy: 0.001
        )
        XCTAssertEqual(
            resultWindow.pointSize.height,
            harness.stillImage.pointSize(
                for: harness.completedSession.composite.metadata.compositePixelSize
            ).height,
            accuracy: 0.001
        )
    }

    func testCancelTearsDownOverlayHudAndSessionState() throws {
        let harness = try makeHarness()
        var cancelledCount = 0
        var confirmedCount = 0

        harness.coordinator.onSessionCancelled = { cancelledCount += 1 }
        harness.coordinator.onSessionConfirmed = { _ in confirmedCount += 1 }

        harness.coordinator.beginCaptureSession()
        harness.overlay.triggerSelection(harness.selectionRect)
        harness.controlPanel.triggerCancel()

        XCTAssertEqual(harness.scrollCapture.startCallCount, 1)
        XCTAssertEqual(harness.scrollCapture.finishCallCount, 0)
        XCTAssertEqual(harness.scrollCapture.cancelCallCount, 1)
        XCTAssertEqual(harness.overlay.dismissCount, 1)
        XCTAssertEqual(harness.controlPanel.dismissCount, 1)
        XCTAssertNil(harness.coordinator.selectedRegion)
        XCTAssertNil(harness.coordinator.lastCompletedScrollCaptureSession)
        XCTAssertEqual(cancelledCount, 1)
        XCTAssertEqual(confirmedCount, 0)
        XCTAssertTrue(harness.resultWindowFactory.createdWindows.isEmpty)
    }

    func testEscapeTearsDownOverlayHudAndSessionState() throws {
        let harness = try makeHarness()
        var cancelledCount = 0
        var confirmedCount = 0

        harness.coordinator.onSessionCancelled = { cancelledCount += 1 }
        harness.coordinator.onSessionConfirmed = { _ in confirmedCount += 1 }

        harness.coordinator.beginCaptureSession()
        harness.overlay.triggerSelection(harness.selectionRect)
        harness.scrollCapture.triggerEscape()

        XCTAssertEqual(harness.scrollCapture.startCallCount, 1)
        XCTAssertEqual(harness.scrollCapture.finishCallCount, 0)
        XCTAssertEqual(harness.scrollCapture.cancelCallCount, 1)
        XCTAssertEqual(harness.overlay.dismissCount, 1)
        XCTAssertEqual(harness.controlPanel.dismissCount, 1)
        XCTAssertNil(harness.coordinator.selectedRegion)
        XCTAssertNil(harness.coordinator.lastCompletedScrollCaptureSession)
        XCTAssertEqual(cancelledCount, 1)
        XCTAssertEqual(confirmedCount, 0)
        XCTAssertTrue(harness.resultWindowFactory.createdWindows.isEmpty)
    }

    private func makeHarness() throws -> SessionHarness {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let stillImage = makeStillImage(screen: screen)
        let selectionRect = CGRect(x: 80, y: 120, width: 240, height: 320)
        let overlay = CaptureOverlaySpy()
        let controlPanel = ScrollControlPanelSpy()
        let scrollCapture = ScrollCaptureSpy()
        let completedSession = try makeCompletedSession(
            stillImage: stillImage,
            selectionRect: selectionRect
        )
        let resultWindowFactory = ResultWindowFactorySpy()

        scrollCapture.finishResult = .success(completedSession)

        let coordinator = CaptureSessionCoordinator(
            permissionCoordinator: PermissionCoordinator(),
            screenCaptureManager: ScreenCaptureManagerStub(),
            stillImageCaptureOverride: { completion in
                completion(.success(stillImage))
            },
            overlayFactory: { _ in overlay },
            controlPanelFactory: { controlPanel },
            scrollCaptureFactory: { scrollCapture },
            resultWindowFactory: { image, pointSize, preferredScreen, defaultFileName in
                resultWindowFactory.makeWindow(
                    image: image,
                    pointSize: pointSize,
                    preferredScreen: preferredScreen,
                    defaultFileName: defaultFileName
                )
            }
        )

        return SessionHarness(
            coordinator: coordinator,
            stillImage: stillImage,
            selectionRect: selectionRect,
            completedSession: completedSession,
            overlay: overlay,
            controlPanel: controlPanel,
            scrollCapture: scrollCapture,
            resultWindowFactory: resultWindowFactory
        )
    }

    private func makeStillImage(screen: NSScreen) -> CaptureSessionCoordinator.StillImage {
        CaptureSessionCoordinator.StillImage(
            screen: screen,
            displayID: 77,
            image: makeImage(width: 32, height: 32, red: 12, green: 34, blue: 56)
        )
    }

    private func makeCompletedSession(
        stillImage: CaptureSessionCoordinator.StillImage,
        selectionRect: CGRect
    ) throws -> ScrollCaptureController.CompletedSession {
        let compositeImage = makeImage(width: 18, height: 44, red: 88, green: 122, blue: 144)
        let startedAt = Date(timeIntervalSince1970: 100)
        let endedAt = Date(timeIntervalSince1970: 145)
        let seedStrip = StitchingEngine.Strip(index: 0, image: compositeImage, capturedAt: startedAt)
        let processedStrip = StitchingEngine.ProcessedStrip(
            strip: seedStrip,
            disposition: .seed,
            translation: nil,
            appendedHeight: 0,
            compositeHeight: compositeImage.height,
            rejectionReason: nil,
            diagnostic: nil
        )
        let metadata = StitchingEngine.CaptureMetadata(
            startedAt: startedAt,
            endedAt: endedAt,
            sourceStripCount: 1,
            acceptedStripCount: 1,
            rejectedStripCount: 0,
            compositePixelSize: CGSize(width: compositeImage.width, height: compositeImage.height),
            processedStrips: [processedStrip]
        )
        let composite = StitchingEngine.Composite(image: compositeImage, metadata: metadata)
        let selectedRegion = CaptureSessionCoordinator.SelectedRegion(
            stillImage: stillImage,
            rect: selectionRect
        )

        return ScrollCaptureController.CompletedSession(
            region: ScrollCaptureController.Region(selectedRegion: selectedRegion),
            composite: composite,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    private func makeImage(
        width: Int,
        height: Int,
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) -> CGImage {
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)

        for row in 0..<height {
            for column in 0..<width {
                let offset = (row * bytesPerRow) + (column * 4)
                bytes[offset] = red
                bytes[offset + 1] = green
                bytes[offset + 2] = blue
                bytes[offset + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        let provider = CGDataProvider(data: Data(bytes) as CFData)

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}

private struct SessionHarness {
    let coordinator: CaptureSessionCoordinator
    let stillImage: CaptureSessionCoordinator.StillImage
    let selectionRect: CGRect
    let completedSession: ScrollCaptureController.CompletedSession
    let overlay: CaptureOverlaySpy
    let controlPanel: ScrollControlPanelSpy
    let scrollCapture: ScrollCaptureSpy
    let resultWindowFactory: ResultWindowFactorySpy
}

private final class CaptureOverlaySpy: CaptureOverlayPresenting {
    var onClose: (() -> Void)?
    var onSelectionFinalized: ((CGRect) -> Void)?
    var selectedRect: CGRect?

    private(set) var presentCount = 0
    private(set) var dismissCount = 0
    private(set) var enterPassthroughModeCount = 0

    func present() {
        presentCount += 1
    }

    func dismissOverlay() {
        dismissCount += 1
    }

    func enterPassthroughMode() {
        enterPassthroughModeCount += 1
    }

    func triggerSelection(_ rect: CGRect) {
        selectedRect = rect
        onSelectionFinalized?(rect)
    }

    func triggerClose() {
        onClose?()
    }
}

private final class ScrollControlPanelSpy: ScrollControlPanelPresenting {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    private(set) var presentCount = 0
    private(set) var dismissCount = 0
    private(set) var lastPresentedRect: CGRect?

    func present(anchoredTo selectionRect: CGRect, on screen: NSScreen) {
        presentCount += 1
        lastPresentedRect = selectionRect
    }

    func dismiss() {
        dismissCount += 1
    }

    func triggerDone() {
        onDone?()
    }

    func triggerCancel() {
        onCancel?()
    }
}

private final class ScrollCaptureSpy: ScrollCaptureSessionControlling {
    var onEscapePressed: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    var startResult: Result<Void, Error> = .success(())
    var finishResult: Result<ScrollCaptureController.CompletedSession, Error>?

    private(set) var startCallCount = 0
    private(set) var finishCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var lastStartedRegion: CaptureSessionCoordinator.SelectedRegion?

    func startSession(
        for selectedRegion: CaptureSessionCoordinator.SelectedRegion,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        startCallCount += 1
        lastStartedRegion = selectedRegion
        completion(startResult)
    }

    func finishSession(
        completion: @escaping (Result<ScrollCaptureController.CompletedSession, Error>) -> Void
    ) {
        finishCallCount += 1
        completion(finishResult ?? .failure(ScrollCaptureController.ScrollCaptureError.noActiveSession))
    }

    func cancelSession(completion: ((Result<Void, Error>) -> Void)?) {
        cancelCallCount += 1
        completion?(.success(()))
    }

    func triggerEscape() {
        onEscapePressed?()
    }
}

private final class ResultWindowFactorySpy {
    private(set) var createdWindows: [ResultWindowSpy] = []

    func makeWindow(
        image: CGImage,
        pointSize: CGSize,
        preferredScreen: NSScreen?,
        defaultFileName: String
    ) -> ResultWindowPresenting {
        let window = ResultWindowSpy(
            image: image,
            pointSize: pointSize,
            preferredScreen: preferredScreen,
            defaultFileName: defaultFileName
        )
        createdWindows.append(window)
        return window
    }
}

private final class ResultWindowSpy: ResultWindowPresenting {
    var onClose: (() -> Void)?

    let image: CGImage
    let pointSize: CGSize
    let preferredScreen: NSScreen?
    let defaultFileName: String

    private(set) var presentCount = 0
    private(set) var closeCount = 0

    init(
        image: CGImage,
        pointSize: CGSize,
        preferredScreen: NSScreen?,
        defaultFileName: String
    ) {
        self.image = image
        self.pointSize = pointSize
        self.preferredScreen = preferredScreen
        self.defaultFileName = defaultFileName
    }

    func present() {
        presentCount += 1
    }

    func close() {
        closeCount += 1
        onClose?()
    }
}

private final class ScreenCaptureManagerStub: ScreenCaptureManaging {
    func captureStillImage(
        for displayID: CGDirectDisplayID,
        completion: @escaping (Result<CGImage, Error>) -> Void
    ) {
        completion(.failure(ScreenCaptureStubError.unexpectedCaptureStillImage))
    }

    func prepareRegionCapture(
        for displayID: CGDirectDisplayID,
        excludingProcessID: pid_t,
        excludingBundleIdentifier: String?,
        completion: @escaping (Result<DisplayCaptureContext, Error>) -> Void
    ) {
        completion(.failure(ScreenCaptureStubError.unexpectedPrepareRegionCapture))
    }

    func captureRegionImage(
        using context: DisplayCaptureContext,
        rect: CGRect,
        completion: @escaping (Result<CGImage, Error>) -> Void
    ) {
        completion(.failure(ScreenCaptureStubError.unexpectedCaptureRegionImage))
    }
}

private enum ScreenCaptureStubError: LocalizedError {
    case unexpectedCaptureStillImage
    case unexpectedPrepareRegionCapture
    case unexpectedCaptureRegionImage

    var errorDescription: String? {
        switch self {
        case .unexpectedCaptureStillImage:
            return "The test stub should not capture a still image."
        case .unexpectedPrepareRegionCapture:
            return "The test stub should not prepare region capture."
        case .unexpectedCaptureRegionImage:
            return "The test stub should not capture a region image."
        }
    }
}
