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

    var onSelectionCompleted: ((CGRect) -> Void)?

    private(set) var state: State = .idle {
        didSet {
            needsDisplay = true
        }
    }

    private let minimumSelectionLength: CGFloat = 8

    override var acceptsFirstResponder: Bool {
        true
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

    override func mouseDown(with event: NSEvent) {
        let point = clampedPoint(for: event)
        state = .selecting(anchor: point, currentRect: CGRect(origin: point, size: .zero))
    }

    override func mouseDragged(with event: NSEvent) {
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

        let dimmedBoundsPath = NSBezierPath(rect: bounds)
        dimmedBoundsPath.appendRect(selectionRect)
        dimmedBoundsPath.windingRule = .evenOdd

        NSColor.black.withAlphaComponent(0.28).setFill()
        dimmedBoundsPath.fill()

        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(rect: selectionRect).fill()

        let shadowPath = NSBezierPath(rect: selectionRect.insetBy(dx: -1, dy: -1))
        shadowPath.lineWidth = 2
        NSColor.black.withAlphaComponent(0.55).setStroke()
        shadowPath.stroke()

        let selectionPath = NSBezierPath(rect: selectionRect)
        selectionPath.lineWidth = 2
        NSColor.white.withAlphaComponent(0.95).setStroke()
        selectionPath.stroke()
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
}
