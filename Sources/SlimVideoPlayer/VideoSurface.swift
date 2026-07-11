import AVFoundation
import AppKit
import SwiftUI

struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    let reverseFrame: ReverseFrame?
    let showsReverseFrame: Bool
    let rotationQuarterTurns: Int

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.player = player
        view.rotationQuarterTurns = rotationQuarterTurns
        return view
    }

    func updateNSView(_ nsView: PlayerView, context: Context) {
        nsView.player = player
        nsView.rotationQuarterTurns = rotationQuarterTurns
        if showsReverseFrame, let reverseFrame {
            nsView.showReverseFrame(reverseFrame)
        } else {
            nsView.showPlayer()
        }
    }
}

final class PlayerView: NSView {
    private let videoContainerLayer = CALayer()
    private let playerLayer = AVPlayerLayer()
    private let reverseLayer = AVSampleBufferDisplayLayer()
    private var displayedReverseTime: Double?

    override func makeBackingLayer() -> CALayer {
        CALayer()
    }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    var rotationQuarterTurns = 0 {
        didSet {
            guard rotationQuarterTurns != oldValue else { return }
            needsLayout = true
        }
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

    override func layout() {
        super.layout()
        let isSideways = rotationQuarterTurns.isMultiple(of: 2) == false
        let containerSize = isSideways
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoContainerLayer.bounds = CGRect(origin: .zero, size: containerSize)
        videoContainerLayer.position = CGPoint(
            x: bounds.midX,
            y: bounds.midY
        )
        let angle = CGFloat(rotationQuarterTurns) * .pi / 2
        videoContainerLayer.setAffineTransform(
            CGAffineTransform(rotationAngle: angle)
        )
        playerLayer.frame = videoContainerLayer.bounds
        reverseLayer.frame = videoContainerLayer.bounds
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            FullScreenController.shared.toggle(window: window)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let requiredModifiers: NSEvent.ModifierFlags = [.command, .control]
        let modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        if event.type == .keyDown,
           event.charactersIgnoringModifiers?.lowercased() == "f",
           modifiers.contains(requiredModifiers) {
            FullScreenController.shared.toggle(window: window)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func showReverseFrame(_ frame: ReverseFrame) {
        reverseLayer.isHidden = false
        guard displayedReverseTime != frame.time else { return }
        displayedReverseTime = frame.time

        if reverseLayer.requiresFlushToResumeDecoding {
            reverseLayer.flush()
        }
        markForImmediateDisplay(frame.sampleBuffer)
        if reverseLayer.isReadyForMoreMediaData {
            reverseLayer.enqueue(frame.sampleBuffer)
        }
    }

    func showPlayer() {
        guard !reverseLayer.isHidden else { return }
        reverseLayer.flushAndRemoveImage()
        reverseLayer.isHidden = true
        displayedReverseTime = nil
    }

    private func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 else {
            return
        }

        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(
                kCMSampleAttachmentKey_DisplayImmediately
            ).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    private func configureLayers() {
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        reverseLayer.videoGravity = .resizeAspect
        reverseLayer.isHidden = true
        layer?.addSublayer(videoContainerLayer)
        videoContainerLayer.addSublayer(playerLayer)
        videoContainerLayer.addSublayer(reverseLayer)
    }
}
