import AppKit

final class ScrollControlPanelController: NSWindowController, NSWindowDelegate {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    private let panelSize = CGSize(width: 176, height: 52)

    init() {
        let panel = ScrollControlPanelWindow(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 176, height: 52)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.animationBehavior = .none

        super.init(window: panel)

        panel.delegate = self
        panel.contentView = makeContentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(anchoredTo selectionRect: CGRect, on screen: NSScreen) {
        guard let window else {
            return
        }

        window.setFrame(frame(for: selectionRect, on: screen), display: true)
        showWindow(nil)
        window.orderFrontRegardless()
    }

    func dismiss() {
        close()
    }

    private func makeContentView() -> NSView {
        let visualEffectView = NSVisualEffectView(frame: CGRect(origin: .zero, size: panelSize))
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 14
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 1
        visualEffectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(handleCancel(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large

        let doneButton = NSButton(title: "Done", target: self, action: #selector(handleDone(_:)))
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .large
        doneButton.keyEquivalent = "\r"
        doneButton.keyEquivalentModifierMask = []

        let stackView = NSStackView(views: [cancelButton, doneButton])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .fillEqually
        stackView.spacing = 8

        let rootView = NSView(frame: CGRect(origin: .zero, size: panelSize))
        rootView.addSubview(visualEffectView)
        visualEffectView.addSubview(stackView)

        NSLayoutConstraint.activate([
            visualEffectView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            visualEffectView.topAnchor.constraint(equalTo: rootView.topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 10),
            stackView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -10),
            stackView.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: 10),
            stackView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor, constant: -10)
        ])

        return rootView
    }

    private func frame(for selectionRect: CGRect, on screen: NSScreen) -> CGRect {
        let padding: CGFloat = 12
        let availableFrame = screen.visibleFrame.insetBy(dx: padding, dy: padding)

        var originX = selectionRect.maxX - panelSize.width
        originX = min(max(originX, availableFrame.minX), availableFrame.maxX - panelSize.width)

        var originY = selectionRect.maxY + padding
        if originY + panelSize.height > availableFrame.maxY {
            originY = selectionRect.minY - panelSize.height - padding
        }

        if originY < availableFrame.minY {
            originY = min(
                max(selectionRect.midY - (panelSize.height / 2), availableFrame.minY),
                availableFrame.maxY - panelSize.height
            )
        }

        return CGRect(origin: CGPoint(x: originX, y: originY), size: panelSize).integral
    }

    @objc
    private func handleDone(_ sender: Any?) {
        onDone?()
    }

    @objc
    private func handleCancel(_ sender: Any?) {
        onCancel?()
    }
}

private final class ScrollControlPanelWindow: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}
