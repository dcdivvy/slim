import AVFoundation
import Observation
import SwiftUI

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
    private(set) var reverseFrame: ReverseFrame?
    private(set) var showsReverseFrame = false

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

    var hasVideo: Bool {
        player.currentItem != nil && duration > 0
    }

    var canStepFrames: Bool {
        hasVideo && !isPlaying
    }

    var canSetRangeStart: Bool {
        hasVideo && currentTime < rangeEnd - frameDuration
    }

    var canSetRangeEnd: Bool {
        hasVideo && currentTime > rangeStart + frameDuration
    }

    var currentFrame: Int {
        max(0, Int((currentTime * framesPerSecond).rounded(.down)))
    }

    var remainingTime: Double {
        max(0, duration - currentTime)
    }

    func open(url: URL) {
        guard url.pathExtension.lowercased() == "mp4" else {
            errorMessage = "Slim Video Player supports MP4 video files."
            return
        }

        loadingTask?.cancel()
        seekGeneration &+= 1
        stopReversePlayback(hideFrame: true)
        player.cancelPendingPrerolls()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        errorMessage = nil
        repeatMode = .off
        playbackDirection = 1
        rotationQuarterTurns = 0
        currentURL = url
        fileName = url.lastPathComponent
        currentTime = 0
        duration = 0
        rangeStart = 0
        rangeEnd = 0

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
                updatePlaybackBoundaryTimes()
                observeEnd(of: item)
                startPlayback()
            } catch {
                guard !Task.isCancelled else { return }
                player.replaceCurrentItem(with: nil)
                duration = 0
                rangeEnd = 0
                errorMessage = "The video could not be opened: \(error.localizedDescription)"
            }
        }
    }

    func togglePlayback() {
        guard hasVideo else { return }

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
        guard hasVideo else { return }
        rotationQuarterTurns = (rotationQuarterTurns + 1) % 4
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
        guard hasVideo else { return }
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
        guard hasVideo else { return }
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
