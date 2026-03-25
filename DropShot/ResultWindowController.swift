import AppKit
import UniformTypeIdentifiers

final class ResultWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let displayedCGImage: CGImage
    private let displayedImage: NSImage
    private let displayedPointSize: NSSize
    private let defaultFileName: String

    private let scrollView = NSScrollView()
    private let imageDocumentView = ResultImageDocumentView(frame: .zero)

    init(
        image: CGImage,
        pointSize: CGSize,
        preferredScreen: NSScreen? = NSScreen.main,
        defaultFileName: String = ResultWindowController.defaultFileName(for: Date())
    ) {
        let resolvedPointSize = Self.resolvedPointSize(pointSize, fallbackImage: image)
        displayedCGImage = image
        displayedPointSize = resolvedPointSize
        displayedImage = NSImage(cgImage: image, size: resolvedPointSize)
        self.defaultFileName = defaultFileName

        let window = NSWindow(
            contentRect: CGRect(
                origin: .zero,
                size: Self.contentSize(for: resolvedPointSize, on: preferredScreen)
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Capture Result"
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 360, height: 280)
        window.center()

        super.init(window: window)

        window.delegate = self
        window.contentView = makeContentView()
        configureImageDocumentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else {
            return
        }

        // In the non-flipped document view (0,0) = bottom-left.
        // Scroll to the top of the content so the user sees the
        // beginning of the stitched image first.
        let docHeight = imageDocumentView.frame.height
        let clipHeight = scrollView.contentView.bounds.height
        let topOrigin = NSPoint(x: 0, y: max(0, docHeight - clipHeight))
        scrollView.contentView.scroll(to: topOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    static func defaultFileName(for date: Date) -> String {
        "DropShot \(fileNameDateFormatter.string(from: date)).png"
    }

    private func makeContentView() -> NSView {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.documentView = imageDocumentView

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(handleCopy(_:)))
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "c"
        copyButton.keyEquivalentModifierMask = [.command]

        let saveButton = NSButton(title: "Save...", target: self, action: #selector(handleSave(_:)))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = [.command]

        let actionStack = NSStackView(views: [copyButton, saveButton])
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 8

        let rootView = NSView(frame: .zero)
        rootView.addSubview(scrollView)
        rootView.addSubview(actionStack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 12),
            scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            actionStack.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            actionStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -12),
            actionStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -12)
        ])

        return rootView
    }

    private func configureImageDocumentView() {
        imageDocumentView.image = displayedImage
        imageDocumentView.frame = CGRect(origin: .zero, size: displayedPointSize)
    }

    @objc
    private func handleCopy(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if pasteboard.writeObjects([displayedImage]) == false {
            NSSound.beep()
        }
    }

    @objc
    private func handleSave(_ sender: Any?) {
        guard let window else {
            return
        }

        guard let pngData = pngData() else {
            presentResultError(ResultWindowError.pngEncodingFailed)
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = defaultFileName

        savePanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = savePanel.url else {
                return
            }

            do {
                try pngData.write(to: url, options: .atomic)
            } catch {
                self?.presentResultError(error)
            }
        }
    }

    private func pngData() -> Data? {
        NSBitmapImageRep(cgImage: displayedCGImage).representation(using: .png, properties: [:])
    }

    private func presentResultError(_ error: Error) {
        let alert = NSAlert(error: error)

        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private static func resolvedPointSize(_ proposedSize: CGSize, fallbackImage: CGImage) -> NSSize {
        let fallbackSize = CGSize(
            width: CGFloat(fallbackImage.width),
            height: CGFloat(fallbackImage.height)
        )
        let width = proposedSize.width.isFinite && proposedSize.width > 0
            ? proposedSize.width
            : fallbackSize.width
        let height = proposedSize.height.isFinite && proposedSize.height > 0
            ? proposedSize.height
            : fallbackSize.height
        return NSSize(width: width, height: height)
    }

    private static func contentSize(for imageSize: CGSize, on screen: NSScreen?) -> CGSize {
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let availableWidth = max(420, min(visibleFrame.width * 0.72, 1080))
        let availableHeight = max(320, min(visibleFrame.height * 0.78, 820))
        let scrollWidth = min(max(imageSize.width, 320), availableWidth - 24)
        let scrollHeight = min(max(imageSize.height, 220), availableHeight - 64)

        return CGSize(width: scrollWidth + 24, height: scrollHeight + 64)
    }

    private static let fileNameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()
}

private final class ResultImageDocumentView: NSView {
    var image: NSImage? {
        didSet {
            needsDisplay = true
        }
    }

    // Use the standard bottom-left coordinate system (isFlipped = false).
    // A flipped view combined with CGContext.makeImage()-backed NSImages can
    // cause a double-flip that renders content upside-down.  The non-flipped
    // coordinate system avoids this ambiguity entirely.
    override var isFlipped: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let image else {
            return
        }

        image.draw(
            in: bounds,
            from: CGRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
    }
}

private enum ResultWindowError: LocalizedError {
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .pngEncodingFailed:
            return "DropShot could not encode the captured image as PNG."
        }
    }
}
