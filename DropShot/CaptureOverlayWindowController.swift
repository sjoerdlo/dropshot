import AppKit
import CoreGraphics

final class CaptureOverlayWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onSelectionFinalized: ((CGRect) -> Void)?
    private(set) var selectedRect: CGRect?

    private let screen: NSScreen
    private let captureImageView = NSImageView()
    private let selectionOverlayView = SelectionOverlayView(frame: .zero)

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
        window.hidesOnDeactivate = false
        window.level = .screenSaver
        window.collectionBehavior = [.fullScreenAuxiliary, .stationary]
        window.animationBehavior = .none

        super.init(window: window)

        selectionOverlayView.onSelectionCompleted = { [weak self] selectionRect in
            self?.handleSelectionCompleted(selectionRect)
        }
        window.delegate = self
        window.contentView = makeContentView(for: screen, image: image)
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
        selectedRect = nil
        close()
    }

    func enterPassthroughMode() {
        guard let window else {
            return
        }

        selectionOverlayView.enterLiveScrollMode()
        captureImageView.isHidden = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private func makeContentView(for screen: NSScreen, image: CGImage) -> NSView {
        captureImageView.translatesAutoresizingMaskIntoConstraints = false
        captureImageView.image = NSImage(cgImage: image, size: screen.frame.size)
        captureImageView.imageScaling = .scaleAxesIndependently

        selectionOverlayView.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        contentView.addSubview(captureImageView)
        contentView.addSubview(selectionOverlayView)

        NSLayoutConstraint.activate([
            captureImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            captureImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            captureImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            captureImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            selectionOverlayView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            selectionOverlayView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            selectionOverlayView.topAnchor.constraint(equalTo: contentView.topAnchor),
            selectionOverlayView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        return contentView
    }

    private func handleSelectionCompleted(_ selectionRect: CGRect) {
        guard let window else {
            return
        }

        let selectionRectInWindow = selectionOverlayView.convert(selectionRect, to: nil)
        let selectionRectOnScreen = window.convertToScreen(selectionRectInWindow).standardized.integral
        selectedRect = selectionRectOnScreen
        onSelectionFinalized?(selectionRectOnScreen)
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
