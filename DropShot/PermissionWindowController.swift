import AppKit

enum PermissionWindowStep {
    case requestAccess
    case openSettings

    var bodyText: String {
        switch self {
        case .requestAccess:
            return "DropShot needs Screen Recording access before Capture can start. Continue so macOS can register DropShot for this permission."
        case .openSettings:
            return "Turn on DropShot in System Settings > Privacy & Security > Screen Recording. After enabling it, fully quit and relaunch DropShot before trying Capture again. If you're running from Xcode, press Stop and then Run again."
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .requestAccess:
            return "Continue"
        case .openSettings:
            return "Open System Settings"
        }
    }
}

final class PermissionWindowController: NSWindowController {
    private let onPrimaryAction: () -> Void
    private let onDismiss: () -> Void
    private let titleLabel = NSTextField(labelWithString: "Allow Screen Recording")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let dismissButton = NSButton(title: "Not Now", target: nil, action: nil)

    init(onPrimaryAction: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onPrimaryAction = onPrimaryAction
        self.onDismiss = onDismiss

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 184),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Screen Recording Needed"
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.contentView = makeContentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(for step: PermissionWindowStep) {
        bodyLabel.stringValue = step.bodyText
        primaryButton.title = step.primaryButtonTitle
        showPermissionWindow()
    }

    func closeWindow() {
        close()
    }

    private func showPermissionWindow() {
        guard let window else {
            return
        }

        window.center()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeContentView() -> NSView {
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)

        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.maximumNumberOfLines = 0

        primaryButton.target = self
        primaryButton.action = #selector(handlePrimaryAction(_:))
        primaryButton.keyEquivalent = "\r"

        dismissButton.target = self
        dismissButton.action = #selector(handleDismiss(_:))

        let buttons = NSStackView(views: [dismissButton, primaryButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.setHuggingPriority(.required, for: .horizontal)

        let stackView = NSStackView(views: [titleLabel, bodyLabel, buttons])
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 14
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stackView.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20)
        ])

        return container
    }

    @objc
    private func handlePrimaryAction(_ sender: Any?) {
        onPrimaryAction()
    }

    @objc
    private func handleDismiss(_ sender: Any?) {
        onDismiss()
    }
}
