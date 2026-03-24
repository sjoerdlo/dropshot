import AppKit
import CoreGraphics

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
