import AppKit
import SwiftUI

struct ImageSurface: NSViewRepresentable {
    @Bindable var model: PlaybackModel

    func makeNSView(context: Context) -> MediaImageView {
        let view = MediaImageView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: MediaImageView, context: Context) {
        nsView.model = model
        nsView.syncFromModel()
    }
}

final class MediaImageView: NSView {
    private let imageContainerLayer = CALayer()
    private let imageLayer = CALayer()
    private var isPanning = false
    private var lastPanPoint: CGPoint = .zero
    private var didPushClosedHandCursor = false
    private var displayedImageIdentity: ObjectIdentifier?

    var model: PlaybackModel?

    override func makeBackingLayer() -> CALayer {
        CALayer()
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    deinit {
        if didPushClosedHandCursor {
            NSCursor.pop()
        }
    }

    func syncFromModel() {
        guard let model else { return }

        let image = model.displayedImage
        let identity = image.map { ObjectIdentifier($0) }
        if identity != displayedImageIdentity {
            displayedImageIdentity = identity
            updateImageContents(image)
        }

        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let model else { return }

        let containerSize = currentContainerSize(for: model.rotationQuarterTurns)
        model.updateImageContainerSize(containerSize)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageContainerLayer.bounds = CGRect(origin: .zero, size: containerSize)
        imageContainerLayer.position = CGPoint(
            x: bounds.midX,
            y: bounds.midY
        )
        let angle = CGFloat(model.rotationQuarterTurns) * .pi / 2
        imageContainerLayer.setAffineTransform(
            CGAffineTransform(rotationAngle: angle)
        )
        imageLayer.frame = imageFrame(
            in: containerSize,
            zoom: model.imageZoomScale,
            pan: model.imagePanOffset,
            image: model.displayedImage
        )
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            endPanningIfNeeded()
            FullScreenController.shared.toggle(window: window)
            return
        }

        isPanning = true
        lastPanPoint = convert(event.locationInWindow, from: nil)
        if !didPushClosedHandCursor {
            NSCursor.closedHand.push()
            didPushClosedHandCursor = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPanning, let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = CGPoint(
            x: point.x - lastPanPoint.x,
            y: point.y - lastPanPoint.y
        )
        lastPanPoint = point
        model.applyImagePan(
            deltaInContainer: convertDeltaToContainer(
                delta,
                rotationQuarterTurns: model.rotationQuarterTurns
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        endPanningIfNeeded()
    }

    override func magnify(with event: NSEvent) {
        guard let model else { return }
        let anchor = convertPointToContainer(
            convert(event.locationInWindow, from: nil),
            rotationQuarterTurns: model.rotationQuarterTurns
        )
        model.adjustImageZoom(
            by: 1 + event.magnification,
            anchorInContainer: anchor
        )
    }

    override func scrollWheel(with event: NSEvent) {
        guard let model else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )

        if modifiers.contains(.command) || !event.hasPreciseScrollingDeltas {
            let anchor = convertPointToContainer(
                viewPoint,
                rotationQuarterTurns: model.rotationQuarterTurns
            )
            let zoomFactor = exp(-event.scrollingDeltaY * 0.01)
            model.adjustImageZoom(by: zoomFactor, anchorInContainer: anchor)
            return
        }

        model.applyImagePan(
            deltaInContainer: convertDeltaToContainer(
                CGPoint(
                    x: event.scrollingDeltaX,
                    y: -event.scrollingDeltaY
                ),
                rotationQuarterTurns: model.rotationQuarterTurns
            )
        )
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        if event.type == .keyDown,
           event.charactersIgnoringModifiers?.lowercased() == "f",
           modifiers.contains([.command, .control]) {
            FullScreenController.shared.toggle(window: window)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func currentContainerSize(for rotationQuarterTurns: Int) -> CGSize {
        let isSideways = rotationQuarterTurns.isMultiple(of: 2) == false
        return isSideways
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size
    }

    private func endPanningIfNeeded() {
        guard isPanning || didPushClosedHandCursor else { return }
        isPanning = false
        if didPushClosedHandCursor {
            NSCursor.pop()
            didPushClosedHandCursor = false
        }
    }

    private func imageFrame(
        in containerSize: CGSize,
        zoom: CGFloat,
        pan: CGPoint,
        image: NSImage?
    ) -> CGRect {
        let fitted = fittedImageSize(image: image, in: containerSize)
        let zoomedSize = CGSize(
            width: fitted.width * zoom,
            height: fitted.height * zoom
        )
        return CGRect(
            x: (containerSize.width - zoomedSize.width) / 2 + pan.x,
            y: (containerSize.height - zoomedSize.height) / 2 + pan.y,
            width: zoomedSize.width,
            height: zoomedSize.height
        )
    }

    private func fittedImageSize(
        image: NSImage?,
        in containerSize: CGSize
    ) -> CGSize {
        guard let image,
              image.size.width > 0,
              image.size.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return .zero
        }

        let imageSize = image.size
        let scale = min(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        return CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
    }

    private func convertPointToContainer(
        _ viewPoint: CGPoint,
        rotationQuarterTurns: Int
    ) -> CGPoint {
        let containerSize = currentContainerSize(for: rotationQuarterTurns)
        let relative = CGPoint(
            x: viewPoint.x - bounds.midX,
            y: viewPoint.y - bounds.midY
        )
        let rotated = rotate(relative, byQuarterTurns: -rotationQuarterTurns)
        return CGPoint(
            x: rotated.x + containerSize.width / 2,
            y: rotated.y + containerSize.height / 2
        )
    }

    private func convertDeltaToContainer(
        _ delta: CGPoint,
        rotationQuarterTurns: Int
    ) -> CGPoint {
        rotate(delta, byQuarterTurns: -rotationQuarterTurns)
    }

    private func rotate(
        _ point: CGPoint,
        byQuarterTurns quarterTurns: Int
    ) -> CGPoint {
        switch quarterTurns.normalizedQuarterTurns {
        case 0:
            point
        case 1:
            CGPoint(x: -point.y, y: point.x)
        case 2:
            CGPoint(x: -point.x, y: -point.y)
        case 3:
            CGPoint(x: point.y, y: -point.x)
        default:
            point
        }
    }

    private func updateImageContents(_ image: NSImage?) {
        guard let image else {
            imageLayer.contents = nil
            return
        }

        var proposedRect = CGRect(origin: .zero, size: image.size)
        imageLayer.contents = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        )
        imageLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    private func configureLayers() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        imageLayer.contentsGravity = .resize
        imageLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(imageContainerLayer)
        imageContainerLayer.addSublayer(imageLayer)
    }
}

private extension Int {
    var normalizedQuarterTurns: Int {
        let modulo = self % 4
        return modulo >= 0 ? modulo : modulo + 4
    }
}
