import AppKit
import CoreGraphics

final class SelectionOverlayView: NSView {
    enum State {
        case idle
        case selecting(anchor: CGPoint, currentRect: CGRect)
        case selected(CGRect)

        var selectionRect: CGRect? {
            switch self {
            case .idle:
                return nil
            case .selecting(_, let currentRect):
                return currentRect
            case .selected(let rect):
                return rect
            }
        }
    }

    enum DisplayMode: Equatable {
        case selection
        case liveScroll
    }

    var onSelectionCompleted: ((CGRect) -> Void)?

    private(set) var state: State = .idle {
        didSet {
            needsDisplay = true
        }
    }
    private var displayMode: DisplayMode = .selection {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    private let minimumSelectionLength: CGFloat = 8
    private let cornerGuideLength: CGFloat = 14
    private let cornerGuideInset: CGFloat = 1

    private let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private let sizeLabelPadding = CGSize(width: 8, height: 4)
    private let sizeLabelOffset: CGFloat = 12
    private let sizeLabelCornerRadius: CGFloat = 5

    override var acceptsFirstResponder: Bool {
        true
    }

    override func resetCursorRects() {
        if displayMode == .selection {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override var isOpaque: Bool {
        false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func enterLiveScrollMode() {
        guard case .selected = state else {
            return
        }

        displayMode = .liveScroll
    }

    override func mouseDown(with event: NSEvent) {
        guard displayMode == .selection else {
            return
        }

        let point = clampedPoint(for: event)
        state = .selecting(anchor: point, currentRect: CGRect(origin: point, size: .zero))
    }

    override func mouseDragged(with event: NSEvent) {
        guard displayMode == .selection else {
            return
        }

        guard case .selecting(let anchor, _) = state else {
            return
        }

        let currentPoint = clampedPoint(for: event)
        state = .selecting(
            anchor: anchor,
            currentRect: Self.normalizedRect(from: anchor, to: currentPoint)
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard displayMode == .selection else {
            return
        }

        guard case .selecting(let anchor, _) = state else {
            return
        }

        let currentPoint = clampedPoint(for: event)
        let finalRect = Self.normalizedRect(from: anchor, to: currentPoint)
        guard
            finalRect.width >= minimumSelectionLength,
            finalRect.height >= minimumSelectionLength
        else {
            state = .idle
            return
        }

        let snappedRect = finalRect.integral
        state = .selected(snappedRect)
        onSelectionCompleted?(snappedRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard
            let selectionRect = state.selectionRect?.intersection(bounds),
            !selectionRect.isNull,
            !selectionRect.isEmpty
        else {
            return
        }

        if displayMode == .selection {
            drawSelectionBackdrop(inside: selectionRect)
        }

        drawSelectionBorder(around: selectionRect)

        if case .selecting = state, displayMode == .selection {
            drawSizeLabel(for: selectionRect)
        }
    }

    private func drawSizeLabel(for selectionRect: CGRect) {
        let scaleFactor = window?.backingScaleFactor ?? 2
        let pixelWidth = Int(selectionRect.width * scaleFactor)
        let pixelHeight = Int(selectionRect.height * scaleFactor)
        guard pixelWidth > 0, pixelHeight > 0 else {
            return
        }

        let widthString = "\(pixelWidth)"
        let heightString = "\(pixelHeight)"
        let multiplicationSign = "\u{00D7}"  // ×

        let labelText = "\(widthString) \(multiplicationSign) \(heightString)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: sizeFont,
            .foregroundColor: NSColor.white
        ]
        let textSize = (labelText as NSString).size(withAttributes: attributes)

        let labelSize = CGSize(
            width: textSize.width + sizeLabelPadding.width * 2,
            height: textSize.height + sizeLabelPadding.height * 2
        )

        // Position the label centered below the selection rect, with a small gap.
        var labelOrigin = CGPoint(
            x: selectionRect.midX - labelSize.width / 2,
            y: selectionRect.minY - sizeLabelOffset - labelSize.height
        )

        // If the label would go below the view, place it above the selection instead.
        if labelOrigin.y < bounds.minY {
            labelOrigin.y = selectionRect.maxY + sizeLabelOffset
        }

        // Clamp horizontally to stay within the view.
        labelOrigin.x = max(bounds.minX + 2, min(labelOrigin.x, bounds.maxX - labelSize.width - 2))

        let labelRect = CGRect(origin: labelOrigin, size: labelSize)

        // Draw dark rounded background.
        let backgroundPath = NSBezierPath(roundedRect: labelRect, xRadius: sizeLabelCornerRadius, yRadius: sizeLabelCornerRadius)
        NSColor.black.withAlphaComponent(0.72).setFill()
        backgroundPath.fill()

        // Draw text centered in the label.
        let textOrigin = CGPoint(
            x: labelRect.minX + sizeLabelPadding.width,
            y: labelRect.minY + sizeLabelPadding.height
        )
        (labelText as NSString).draw(at: textOrigin, withAttributes: attributes)
    }

    private func clampedPoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let clampedX = min(max(point.x, bounds.minX), bounds.maxX)
        let clampedY = min(max(point.y, bounds.minY), bounds.maxY)
        return CGPoint(x: clampedX, y: clampedY)
    }

    private static func normalizedRect(from startPoint: CGPoint, to endPoint: CGPoint) -> CGRect {
        CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }

    private func drawSelectionBackdrop(inside selectionRect: CGRect) {
        let dimmedBoundsPath = NSBezierPath(rect: bounds)
        dimmedBoundsPath.appendRect(selectionRect)
        dimmedBoundsPath.windingRule = .evenOdd

        NSColor.black.withAlphaComponent(0.28).setFill()
        dimmedBoundsPath.fill()

        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(rect: selectionRect).fill()
    }

    private func drawSelectionBorder(around selectionRect: CGRect) {
        let shadowPath = NSBezierPath(rect: selectionRect.insetBy(dx: -1, dy: -1))
        shadowPath.lineWidth = displayMode == .liveScroll ? 4 : 2
        NSColor.black.withAlphaComponent(displayMode == .liveScroll ? 0.72 : 0.55).setStroke()
        shadowPath.stroke()

        let selectionPath = NSBezierPath(rect: selectionRect)
        selectionPath.lineWidth = 2
        NSColor.white.withAlphaComponent(0.95).setStroke()
        selectionPath.stroke()

        guard displayMode == .liveScroll else {
            return
        }

        drawCornerGuides(around: selectionRect)
    }

    private func drawCornerGuides(around selectionRect: CGRect) {
        let insetRect = selectionRect.insetBy(dx: cornerGuideInset, dy: cornerGuideInset)
        let guideLength = min(cornerGuideLength, max(0, min(insetRect.width, insetRect.height) / 2))
        guard guideLength > 0 else {
            return
        }

        let cornerPaths = [
            linePath(from: CGPoint(x: insetRect.minX, y: insetRect.minY), to: CGPoint(x: insetRect.minX + guideLength, y: insetRect.minY)),
            linePath(from: CGPoint(x: insetRect.minX, y: insetRect.minY), to: CGPoint(x: insetRect.minX, y: insetRect.minY + guideLength)),
            linePath(from: CGPoint(x: insetRect.maxX, y: insetRect.minY), to: CGPoint(x: insetRect.maxX - guideLength, y: insetRect.minY)),
            linePath(from: CGPoint(x: insetRect.maxX, y: insetRect.minY), to: CGPoint(x: insetRect.maxX, y: insetRect.minY + guideLength)),
            linePath(from: CGPoint(x: insetRect.minX, y: insetRect.maxY), to: CGPoint(x: insetRect.minX + guideLength, y: insetRect.maxY)),
            linePath(from: CGPoint(x: insetRect.minX, y: insetRect.maxY), to: CGPoint(x: insetRect.minX, y: insetRect.maxY - guideLength)),
            linePath(from: CGPoint(x: insetRect.maxX, y: insetRect.maxY), to: CGPoint(x: insetRect.maxX - guideLength, y: insetRect.maxY)),
            linePath(from: CGPoint(x: insetRect.maxX, y: insetRect.maxY), to: CGPoint(x: insetRect.maxX, y: insetRect.maxY - guideLength))
        ]

        for cornerPath in cornerPaths {
            cornerPath.lineWidth = 5
            NSColor.black.withAlphaComponent(0.78).setStroke()
            cornerPath.stroke()

            cornerPath.lineWidth = 3
            NSColor.white.withAlphaComponent(0.98).setStroke()
            cornerPath.stroke()
        }
    }

    private func linePath(from startPoint: CGPoint, to endPoint: CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.move(to: startPoint)
        path.line(to: endPoint)
        return path
    }
}
