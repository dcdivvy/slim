@preconcurrency import AVFoundation
import CoreVideo

struct ReverseFrame: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let time: Double
}

enum ReverseFrameDecoder {
    static func decode(
        url: URL,
        start: Double,
        end: Double
    ) async throws -> [ReverseFrame] {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ReverseDecodeError.missingVideoTrack
            }

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                ]
            )
            output.alwaysCopiesSampleData = false

            guard reader.canAdd(output) else {
                throw ReverseDecodeError.cannotAddTrackOutput
            }
            reader.add(output)
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                end: CMTime(seconds: end, preferredTimescale: 600)
            )

            guard reader.startReading() else {
                throw reader.error ?? ReverseDecodeError.cannotStartReader
            }

            var frames: [ReverseFrame] = []
            while !Task.isCancelled,
                  let sampleBuffer = output.copyNextSampleBuffer() {
                guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
                    continue
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                guard time.isFinite, time >= start, time <= end else { continue }
                frames.append(ReverseFrame(sampleBuffer: sampleBuffer, time: time))
            }

            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            if reader.status == .failed {
                throw reader.error ?? ReverseDecodeError.readingFailed
            }

            return frames.sorted { $0.time < $1.time }
        }.value
    }
}

private enum ReverseDecodeError: LocalizedError {
    case missingVideoTrack
    case cannotAddTrackOutput
    case cannotStartReader
    case readingFailed

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            "The video does not contain a readable video track."
        case .cannotAddTrackOutput:
            "The reverse decoder could not configure its video output."
        case .cannotStartReader:
            "The reverse decoder could not start reading the video."
        case .readingFailed:
            "The reverse decoder stopped while reading the video."
        }
    }
}
