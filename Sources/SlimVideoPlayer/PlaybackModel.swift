import AppKit
import AVFoundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum MediaKind {
    case video
    case image
}

enum MediaFileSupport {
    static let allowedContentTypes: [UTType] = [
        .mpeg4Movie,
        .jpeg,
        .png,
    ]

    static func kind(for url: URL) -> MediaKind? {
        switch url.pathExtension.lowercased() {
        case "mp4":
            .video
        case "jpg", "jpeg", "png":
            .image
        default:
            nil
        }
    }

    static func isSupported(_ url: URL) -> Bool {
        kind(for: url) != nil
    }
}

enum RepeatMode: Int, CaseIterable {
    case off
    case fromStart
    case bounce

    var title: String {
        switch self {
        case .off: "Off"
        case .fromStart: "From Start"
        case .bounce: "Bounce"
        }
    }
}

@MainActor
@Observable
final class PlaybackModel {
    let player = AVPlayer()

    var isFileImporterPresented = false
    var isPlaying = false
    var isFullScreen = false
    private(set) var repeatMode = RepeatMode.off
    var currentTime = 0.0
    var duration = 0.0
    var framesPerSecond = 30.0
    private(set) var rotationQuarterTurns = 0
    var rangeStart = 0.0
    var rangeEnd = 0.0
    var fileName: String?
    var errorMessage: String?
    private(set) var isMediaReady = false
    private(set) var mediaKind: MediaKind?
    private(set) var displayedImage: NSImage?
    private(set) var imageZoomScale: CGFloat = 1
    private(set) var imagePanOffset: CGPoint = .zero
    private(set) var reverseFrame: ReverseFrame?
    private(set) var showsReverseFrame = false

    @ObservationIgnored var imageContainerSize: CGSize = .zero
    @ObservationIgnored nonisolated(unsafe) private var timeObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var loadingTask: Task<Void, Never>?
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var seekGeneration: UInt64 = 0
    @ObservationIgnored private var playbackDirection = 1.0
    @ObservationIgnored private var currentURL: URL?
    @ObservationIgnored private var reverseFrames: [ReverseFrame] = []
    @ObservationIgnored private var prefetchedReverseFrames: [ReverseFrame] = []
    @ObservationIgnored private var reverseDecodeTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var reverseTimer: Timer?
    @ObservationIgnored private var reverseGeneration: UInt64 = 0
    @ObservationIgnored private var reverseNextWindowEnd = 0.0

    init() {
        player.actionAtItemEnd = .pause
        installPeriodicTimeObserver()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        reverseTimer?.invalidate()
    }

    var hasMedia: Bool {
        isMediaReady
    }

    var isVideo: Bool {
        hasMedia && mediaKind == .video
    }

    var isImage: Bool {
        hasMedia && mediaKind == .image
    }

    var canStepFrames: Bool {
        isVideo && !isPlaying
    }

    var canSetRangeStart: Bool {
        isVideo && currentTime < rangeEnd - frameDuration
    }

    var canSetRangeEnd: Bool {
        isVideo && currentTime > rangeStart + frameDuration
    }

    var currentFrame: Int {
        max(0, Int((currentTime * framesPerSecond).rounded(.down)))
    }

    var remainingTime: Double {
        max(0, duration - currentTime)
    }

    func open(url: URL) {
        guard let kind = MediaFileSupport.kind(for: url) else {
            errorMessage =
                "Slim supports MP4 videos and JPG or PNG images."
            return
        }

        resetForOpening(url: url)

        switch kind {
        case .video:
            openVideo(url: url)
        case .image:
            openImage(url: url)
        }
    }

    func togglePlayback() {
        guard isVideo else { return }

        if isPlaying {
            pause()
        } else {
            if playbackDirection < 0 {
                if currentTime <= rangeStart + frameDuration {
                    playbackDirection = 1
                    seek(to: rangeStart, resumeAfterSeek: true)
                } else {
                    startPlayback()
                }
            } else if currentTime >= rangeEnd - frameDuration {
                if repeatMode == .bounce {
                    playbackDirection = -1
                    seek(to: rangeEnd, resumeAfterSeek: true)
                } else {
                    playbackDirection = 1
                    seek(to: rangeStart, resumeAfterSeek: true)
                }
            } else {
                startPlayback()
            }
        }
    }

    func pause() {
        player.cancelPendingPrerolls()
        player.pause()
        if playbackDirection < 0 {
            stopReversePlayback(hideFrame: false)
        }
        isPlaying = false
    }

    func stepFrame(direction: Int) {
        guard canStepFrames else { return }
        let target = currentTime + (Double(direction) * frameDuration)
        seek(to: target)
    }

    func cycleRepeatMode() {
        guard isVideo else { return }
        let modes = RepeatMode.allCases
        let nextIndex = (repeatMode.rawValue + 1) % modes.count
        repeatMode = modes[nextIndex]

        if repeatMode != .bounce && playbackDirection < 0 {
            let shouldResume = isPlaying
            playbackDirection = 1
            seek(to: currentTime, resumeAfterSeek: shouldResume)
        }
    }

    func rotateCounterclockwise() {
        guard hasMedia else { return }
        rotationQuarterTurns = (rotationQuarterTurns + 1) % 4
    }

    func updateImageContainerSize(_ size: CGSize) {
        guard isImage, size.width > 0, size.height > 0 else { return }
        if size != imageContainerSize {
            imageContainerSize = size
        }
        clampImagePanOffset()
    }

    func applyImagePan(deltaInContainer delta: CGPoint) {
        guard isImage else { return }
        imagePanOffset.x += delta.x
        imagePanOffset.y += delta.y
        clampImagePanOffset()
    }

    func adjustImageZoom(by factor: CGFloat, anchorInContainer: CGPoint? = nil) {
        guard isImage else { return }
        let oldZoom = imageZoomScale
        let newZoom = min(
            max(oldZoom * factor, Self.minimumImageZoom),
            Self.maximumImageZoom
        )
        guard abs(newZoom - oldZoom) > 0.000_1 else { return }
        setImageZoom(newZoom, anchorInContainer: anchorInContainer)
    }

    func zoomImageIn() {
        adjustImageZoom(by: Self.imageZoomStep)
    }

    func zoomImageOut() {
        adjustImageZoom(by: 1 / Self.imageZoomStep)
    }

    func toggleImageZoomFitOrActual() {
        guard isImage else { return }
        if isImageZoomedToFit {
            setImageZoom(actualSizeZoomScale)
        } else if isImageZoomedToActualSize {
            setImageZoom(1)
        } else {
            setImageZoom(actualSizeZoomScale)
        }
    }

    func setRangeStartToCurrentTime() {
        guard canSetRangeStart else { return }
        let newStart = currentTime
        let shouldResume = isPlaying
        updateRange(start: newStart, end: rangeEnd)
        seek(to: newStart, resumeAfterSeek: shouldResume)
    }

    func setRangeEndToCurrentTime() {
        guard canSetRangeEnd else { return }
        updateRange(start: rangeStart, end: currentTime)
    }

    func seek(to time: Double, resumeAfterSeek: Bool? = nil) {
        guard isVideo else { return }
        let clampedTime = min(max(time, rangeStart), rangeEnd)
        let shouldResume = resumeAfterSeek ?? isPlaying

        if playbackDirection < 0 {
            stopReversePlayback(hideFrame: false)
        }
        seekGeneration &+= 1
        let generation = seekGeneration
        isSeeking = true
        currentTime = clampedTime
        let target = CMTime(seconds: clampedTime, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] finished in
            Task { @MainActor in
                guard let self,
                      generation == self.seekGeneration else {
                    return
                }
                self.isSeeking = false
                guard finished else { return }
                if shouldResume {
                    self.startPlayback()
                } else {
                    self.hideReverseFrame()
                }
            }
        }
    }

    func updateRange(start: Double, end: Double) {
        guard isVideo else { return }
        let minimumGap = min(frameDuration, duration)
        rangeStart = min(max(0, start), rangeEnd - minimumGap)
        rangeEnd = max(min(duration, end), rangeStart + minimumGap)
        updatePlaybackBoundaryTimes()

        if currentTime < rangeStart || currentTime > rangeEnd {
            seek(to: min(max(currentTime, rangeStart), rangeEnd))
        }
    }

    func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00.000" }
        let milliseconds = Int((max(0, seconds) * 1_000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let secs = (milliseconds / 1_000) % 60
        let millis = milliseconds % 1_000

        if hours > 0 {
            return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
        }
        return String(format: "%02d:%02d.%03d", minutes, secs, millis)
    }

    private func resetForOpening(url: URL) {
        loadingTask?.cancel()
        seekGeneration &+= 1
        stopReversePlayback(hideFrame: true)
        player.cancelPendingPrerolls()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isMediaReady = false
        mediaKind = nil
        displayedImage = nil
        isPlaying = false
        errorMessage = nil
        repeatMode = .off
        playbackDirection = 1
        rotationQuarterTurns = 0
        imageZoomScale = 1
        imagePanOffset = .zero
        imageContainerSize = .zero
        currentURL = url
        fileName = url.lastPathComponent
        currentTime = 0
        duration = 0
        rangeStart = 0
        rangeEnd = 0
        framesPerSecond = 30
    }

    private static let minimumImageZoom: CGFloat = 0.05
    private static let maximumImageZoom: CGFloat = 20
    private static let imageZoomStep: CGFloat = 1.25
    private static let imageZoomMatchTolerance: CGFloat = 0.02

    private var isImageZoomedToFit: Bool {
        abs(imageZoomScale - 1) <= Self.imageZoomMatchTolerance
    }

    private var isImageZoomedToActualSize: Bool {
        abs(imageZoomScale - actualSizeZoomScale)
            <= Self.imageZoomMatchTolerance
    }

    private var actualSizeZoomScale: CGFloat {
        let fitted = fittedImageSize(in: imageContainerSize)
        guard fitted.width > 0, let image = displayedImage else {
            return 1
        }
        return min(
            max(image.size.width / fitted.width, Self.minimumImageZoom),
            Self.maximumImageZoom
        )
    }

    private func setImageZoom(
        _ newZoom: CGFloat,
        anchorInContainer: CGPoint? = nil
    ) {
        let containerSize = imageContainerSize
        let zoom = min(
            max(newZoom, Self.minimumImageZoom),
            Self.maximumImageZoom
        )
        let oldZoom = imageZoomScale
        let anchor = anchorInContainer
            ?? CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        let oldFrame = imageFrame(in: containerSize, zoom: oldZoom)
        let contentX = (anchor.x - oldFrame.origin.x) / max(oldFrame.width, 1)
        let contentY = (anchor.y - oldFrame.origin.y) / max(oldFrame.height, 1)

        imageZoomScale = zoom
        let fitted = fittedImageSize(in: containerSize)
        let zoomedSize = CGSize(
            width: fitted.width * zoom,
            height: fitted.height * zoom
        )
        let newOrigin = CGPoint(
            x: anchor.x - contentX * zoomedSize.width,
            y: anchor.y - contentY * zoomedSize.height
        )
        imagePanOffset = CGPoint(
            x: newOrigin.x - (containerSize.width - zoomedSize.width) / 2,
            y: newOrigin.y - (containerSize.height - zoomedSize.height) / 2
        )
        clampImagePanOffset()
    }

    private func clampImagePanOffset() {
        let containerSize = imageContainerSize
        let fitted = fittedImageSize(in: containerSize)
        let zoomedSize = CGSize(
            width: fitted.width * imageZoomScale,
            height: fitted.height * imageZoomScale
        )

        var clamped = imagePanOffset

        if zoomedSize.width <= containerSize.width {
            clamped.x = 0
        } else {
            let limit = (zoomedSize.width - containerSize.width) / 2
            clamped.x = min(max(clamped.x, -limit), limit)
        }

        if zoomedSize.height <= containerSize.height {
            clamped.y = 0
        } else {
            let limit = (zoomedSize.height - containerSize.height) / 2
            clamped.y = min(max(clamped.y, -limit), limit)
        }

        if clamped != imagePanOffset {
            imagePanOffset = clamped
        }
    }

    private func fittedImageSize(in containerSize: CGSize) -> CGSize {
        guard let image = displayedImage,
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

    private func imageFrame(in containerSize: CGSize, zoom: CGFloat) -> CGRect {
        let fitted = fittedImageSize(in: containerSize)
        let zoomedSize = CGSize(
            width: fitted.width * zoom,
            height: fitted.height * zoom
        )
        return CGRect(
            x: (containerSize.width - zoomedSize.width) / 2 + imagePanOffset.x,
            y: (containerSize.height - zoomedSize.height) / 2 + imagePanOffset.y,
            width: zoomedSize.width,
            height: zoomedSize.height
        )
    }

    private func openVideo(url: URL) {
        let asset = AVURLAsset(url: url)
        loadingTask = Task { [weak self] in
            guard let self else { return }

            do {
                let loadedDuration = try await asset.load(.duration)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard !Task.isCancelled else { return }

                let seconds = loadedDuration.seconds
                guard seconds.isFinite, seconds > 0 else {
                    throw PlaybackError.invalidDuration
                }

                var detectedFrameRate = 30.0
                if let track = tracks.first {
                    let rate = try await track.load(.nominalFrameRate)
                    if rate > 0 {
                        detectedFrameRate = Double(rate)
                    }
                }

                guard !Task.isCancelled else { return }
                duration = seconds
                currentTime = 0
                rangeStart = 0
                rangeEnd = seconds
                framesPerSecond = detectedFrameRate

                let item = AVPlayerItem(asset: asset)
                player.replaceCurrentItem(with: item)
                mediaKind = .video
                isMediaReady = true
                updatePlaybackBoundaryTimes()
                observeEnd(of: item)
                startPlayback()
            } catch {
                guard !Task.isCancelled else { return }
                player.replaceCurrentItem(with: nil)
                isMediaReady = false
                mediaKind = nil
                duration = 0
                rangeEnd = 0
                errorMessage =
                    "The media could not be opened: \(error.localizedDescription)"
            }
        }
    }

    private func openImage(url: URL) {
        guard let image = NSImage(contentsOf: url),
              image.isValid,
              image.size.width > 0,
              image.size.height > 0 else {
            errorMessage = "The image could not be opened."
            currentURL = nil
            fileName = nil
            return
        }

        displayedImage = image
        mediaKind = .image
        isMediaReady = true
    }

    private var frameDuration: Double {
        1 / max(framesPerSecond, 1)
    }

    private var boundaryTolerance: Double {
        max(frameDuration, 1.0 / 30.0)
    }

    private func updatePlaybackBoundaryTimes() {
        guard let item = player.currentItem else { return }
        item.forwardPlaybackEndTime = CMTime(
            seconds: rangeEnd,
            preferredTimescale: 600
        )
        item.reversePlaybackEndTime = CMTime(
            seconds: rangeStart,
            preferredTimescale: 600
        )
    }

    private func installPeriodicTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isSeeking else { return }
                guard self.playbackDirection > 0 else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self.currentTime = seconds

                guard self.isPlaying else { return }
                if self.playbackDirection > 0,
                   seconds >= self.rangeEnd - self.boundaryTolerance {
                    self.handleRangeEnd()
                } else if self.repeatMode == .bounce,
                          self.playbackDirection < 0,
                          seconds <= self.rangeStart + self.boundaryTolerance {
                    self.handleRangeStart()
                }
            }
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePlaybackEndNotification()
            }
        }
    }

    private func handlePlaybackEndNotification() {
        guard isPlaying, !isSeeking else { return }

        if playbackDirection < 0 {
            let time = player.currentTime().seconds
            if time.isFinite, time <= rangeStart + boundaryTolerance {
                handleRangeStart()
            }
        } else {
            handleRangeEnd()
        }
    }

    private func handleRangeEnd() {
        guard isPlaying, playbackDirection > 0 else { return }

        switch repeatMode {
        case .off:
            player.pause()
            isPlaying = false
            seek(to: rangeEnd, resumeAfterSeek: false)
        case .fromStart:
            playbackDirection = 1
            seek(to: rangeStart, resumeAfterSeek: true)
        case .bounce:
            playbackDirection = -1
            seek(to: rangeEnd, resumeAfterSeek: true)
        }
    }

    private func handleRangeStart() {
        guard repeatMode == .bounce, isPlaying, playbackDirection < 0 else {
            return
        }
        playbackDirection = 1
        seek(to: rangeStart, resumeAfterSeek: true)
    }

    private func startPlayback() {
        player.cancelPendingPrerolls()

        guard playbackDirection < 0 else {
            stopReversePlayback(hideFrame: true)
            player.isMuted = false
            player.rate = 1
            isPlaying = true
            return
        }

        player.pause()
        player.isMuted = true
        isPlaying = true
        startReversePlayback(at: currentTime)
    }

    private func startReversePlayback(at time: Double) {
        stopReversePlayback(hideFrame: false)
        reverseNextWindowEnd = min(max(time, rangeStart), rangeEnd)

        guard reverseNextWindowEnd > rangeStart + frameDuration else {
            handleRangeStart()
            return
        }
        requestReverseWindow(endingAt: reverseNextWindowEnd, isInitial: true)
    }

    private func requestReverseWindow(endingAt end: Double, isInitial: Bool) {
        guard reverseDecodeTask == nil,
              let currentURL,
              end > rangeStart else {
            return
        }

        let start = max(rangeStart, end - 0.75)
        let generation = reverseGeneration
        reverseDecodeTask = Task { [weak self] in
            do {
                let frames = try await ReverseFrameDecoder.decode(
                    url: currentURL,
                    start: start,
                    end: end
                )
                guard let self,
                      generation == self.reverseGeneration,
                      self.playbackDirection < 0 else {
                    return
                }

                self.reverseDecodeTask = nil
                self.reverseNextWindowEnd = start
                if isInitial {
                    self.reverseFrames = frames
                    self.startReverseTimer()
                } else {
                    self.prefetchedReverseFrames = frames
                }
            } catch is CancellationError {
                // A seek, pause, or direction change superseded this window.
            } catch {
                guard let self, generation == self.reverseGeneration else {
                    return
                }
                self.reverseDecodeTask = nil
                self.stopReversePlayback(hideFrame: true)
                self.player.rate = -1
                self.isPlaying = true
            }
        }
    }

    private func startReverseTimer() {
        reverseTimer?.invalidate()
        let refreshRate = min(max(framesPerSecond, 1), 60)
        let timer = Timer(timeInterval: 1 / refreshRate, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.displayNextReverseFrame()
            }
        }
        reverseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        displayNextReverseFrame()
    }

    private func displayNextReverseFrame() {
        guard isPlaying, playbackDirection < 0 else { return }

        if reverseFrames.isEmpty, !prefetchedReverseFrames.isEmpty {
            reverseFrames = prefetchedReverseFrames
            prefetchedReverseFrames.removeAll(keepingCapacity: true)
        }

        guard let frame = reverseFrames.popLast() else {
            if reverseDecodeTask == nil {
                if reverseNextWindowEnd <= rangeStart + frameDuration {
                    handleRangeStart()
                } else {
                    requestReverseWindow(
                        endingAt: reverseNextWindowEnd,
                        isInitial: reverseFrame == nil
                    )
                }
            }
            return
        }

        reverseFrame = frame
        showsReverseFrame = true
        currentTime = frame.time

        if frame.time <= rangeStart + frameDuration {
            handleRangeStart()
            return
        }

        let prefetchThreshold = max(3, Int(framesPerSecond * 0.6))
        if reverseFrames.count <= prefetchThreshold,
           prefetchedReverseFrames.isEmpty,
           reverseDecodeTask == nil,
           reverseNextWindowEnd > rangeStart {
            requestReverseWindow(
                endingAt: reverseNextWindowEnd,
                isInitial: false
            )
        }
    }

    private func stopReversePlayback(hideFrame: Bool) {
        reverseGeneration &+= 1
        reverseDecodeTask?.cancel()
        reverseDecodeTask = nil
        reverseTimer?.invalidate()
        reverseTimer = nil
        reverseFrames.removeAll(keepingCapacity: false)
        prefetchedReverseFrames.removeAll(keepingCapacity: false)

        if hideFrame {
            hideReverseFrame()
        }
    }

    private func hideReverseFrame() {
        showsReverseFrame = false
        reverseFrame = nil
    }
}

private enum PlaybackError: LocalizedError {
    case invalidDuration

    var errorDescription: String? {
        "The selected file does not contain a playable video duration."
    }
}
