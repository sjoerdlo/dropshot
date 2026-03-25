import AppKit

final class DragThumbnailWindowController: NSWindowController {
    var onClose: (() -> Void)?
    var onClicked: (() -> Void)?

    private let capturedImage: CGImage
    private let defaultFileName: String
    private let thumbnailView: DragThumbnailView
    private var dismissTimer: Timer?
    private let autoDismissDelay: TimeInterval = 6

    init(
        image: CGImage,
        preferredScreen: NSScreen? = NSScreen.main,
        defaultFileName: String
    ) {
        capturedImage = image
        self.defaultFileName = defaultFileName

        let thumbnailSize = Self.thumbnailSize(for: image)
        thumbnailView = DragThumbnailView(
            frame: CGRect(origin: .zero, size: thumbnailSize),
            image: image,
            defaultFileName: defaultFileName
        )

        let windowFrame = Self.windowFrame(thumbnailSize: thumbnailSize, on: preferredScreen)
        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.animationBehavior = .utilityWindow
        window.isMovableByWindowBackground = false

        super.init(window: window)

        thumbnailView.onClicked = { [weak self] in
            self?.handleClick()
        }
        thumbnailView.onDragStarted = { [weak self] in
            self?.dismissTimer?.invalidate()
            self?.dismissTimer = nil
        }
        thumbnailView.onDragEnded = { [weak self] didComplete in
            if didComplete {
                self?.dismiss()
            } else {
                self?.resetAutoDismissTimer()
            }
        }

        window.contentView = thumbnailView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else {
            return
        }

        window.alphaValue = 0
        showWindow(nil)
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }

        resetAutoDismissTimer()
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil

        guard let window else {
            onClose?()
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.close()
            self?.onClose?()
        })
    }

    private func handleClick() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        onClicked?()
    }

    private func resetAutoDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: autoDismissDelay, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    private static func thumbnailSize(for image: CGImage) -> CGSize {
        let maxThumbnailWidth: CGFloat = 160
        let maxThumbnailHeight: CGFloat = 160
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let scale = min(maxThumbnailWidth / imageWidth, maxThumbnailHeight / imageHeight, 1)
        let width = max(80, (imageWidth * scale).rounded())
        let height = max(60, (imageHeight * scale).rounded())
        // Add padding for the rounded rect container
        return CGSize(width: width + 16, height: height + 16)
    }

    private static func windowFrame(thumbnailSize: CGSize, on screen: NSScreen?) -> CGRect {
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 20
        let x = visibleFrame.maxX - thumbnailSize.width - margin
        let y = visibleFrame.minY + margin
        return CGRect(x: x, y: y, width: thumbnailSize.width, height: thumbnailSize.height)
    }
}

private final class DragThumbnailView: NSView, NSDraggingSource {
    var onClicked: (() -> Void)?
    var onDragStarted: (() -> Void)?
    var onDragEnded: ((Bool) -> Void)?

    private let capturedImage: CGImage
    private let nsImage: NSImage
    private let defaultFileName: String
    private let cornerRadius: CGFloat = 10
    private var isDragging = false
    private var mouseDownLocation: CGPoint?

    init(frame frameRect: NSRect, image: CGImage, defaultFileName: String) {
        capturedImage = image
        self.defaultFileName = defaultFileName

        let imageSize = CGSize(
            width: frameRect.width - 16,
            height: frameRect.height - 16
        )
        nsImage = NSImage(cgImage: image, size: imageSize)

        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow?.shadowOffset = CGSize(width: 0, height: -2)
        shadow?.shadowBlurRadius = 8
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let backgroundPath = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)

        // Dark background
        NSColor(white: 0.15, alpha: 0.95).setFill()
        backgroundPath.fill()

        // Draw the image inset
        let imageRect = bounds.insetBy(dx: 8, dy: 8)
        nsImage.draw(
            in: imageRect,
            from: CGRect(origin: .zero, size: nsImage.size),
            operation: .sourceOver,
            fraction: 1
        )

        // Subtle border
        NSColor.white.withAlphaComponent(0.15).setStroke()
        backgroundPath.lineWidth = 0.5
        backgroundPath.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let mouseDownLocation else {
            return
        }

        let currentLocation = convert(event.locationInWindow, from: nil)
        let dx = currentLocation.x - mouseDownLocation.x
        let dy = currentLocation.y - mouseDownLocation.y
        let distance = sqrt(dx * dx + dy * dy)

        // Require a minimum drag distance before starting
        guard distance > 4 else {
            return
        }

        isDragging = true
        onDragStarted?()
        beginDrag(from: event)
    }

    override func mouseUp(with event: NSEvent) {
        if !isDragging {
            onClicked?()
        }
        isDragging = false
        mouseDownLocation = nil
    }

    private func beginDrag(from event: NSEvent) {
        let bitmapRep = NSBitmapImageRep(cgImage: capturedImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]),
              let tiffData = bitmapRep.tiffRepresentation else {
            return
        }

        // Use a single NSPasteboardItem that advertises multiple types.
        // TIFF is the standard macOS image interchange format that most
        // apps accept; PNG is provided for apps that specifically want it;
        // the fileURL type enables file-based drops (e.g. Finder, chat apps).
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(tiffData, forType: .tiff)
        pasteboardItem.setData(pngData, forType: .png)

        // Write PNG to a temp file so we can also offer a fileURL.
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(defaultFileName)
        try? pngData.write(to: tempURL, options: .atomic)
        pasteboardItem.setString(tempURL.absoluteString, forType: .fileURL)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let imageRect = bounds.insetBy(dx: 8, dy: 8)
        draggingItem.setDraggingFrame(imageRect, contents: nsImage)

        beginDraggingSession(
            with: [draggingItem],
            event: event,
            source: self
        )
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : [.copy]
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isDragging = false
        mouseDownLocation = nil
        onDragEnded?(operation != [])
    }
}
