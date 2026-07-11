import AppKit
import SwiftUI

struct RangeTimeline: View {
    @Bindable var model: PlaybackModel

    private let handleWidth = 12.0
    private let trackHeight = 8.0

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let startX = xPosition(for: model.rangeStart, width: width)
            let endX = xPosition(for: model.rangeEnd, width: width)
            let playheadX = xPosition(for: model.currentTime, width: width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.28))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(.tint.opacity(0.45))
                    .frame(width: max(0, endX - startX), height: trackHeight)
                    .offset(x: startX)

                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: 24)
                    .shadow(color: .black.opacity(0.65), radius: 1)
                    .offset(x: playheadX - 1)
                    .gesture(playheadGesture(width: width))

                trimHandle(systemName: "chevron.right.2", isLeading: true)
                    .offset(x: startX - (handleWidth / 2))
                    .gesture(startGesture(width: width))

                trimHandle(systemName: "chevron.left.2", isLeading: false)
                    .offset(x: endX - (handleWidth / 2))
                    .gesture(endGesture(width: width))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(playheadGesture(width: width))
            .coordinateSpace(name: "timeline")
            .onHover { isHovering in
                if isHovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
        }
        .frame(height: 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback timeline")
    }

    private func trimHandle(systemName: String, isLeading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.tint)
            .frame(width: handleWidth, height: 24)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(isLeading ? "Playback range start" : "Playback range end")
    }

    private func playheadGesture(width: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { value in
                model.seek(to: time(for: value.location.x, width: width))
            }
    }

    private func startGesture(width: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { value in
                model.updateRange(
                    start: time(for: value.location.x, width: width),
                    end: model.rangeEnd
                )
            }
    }

    private func endGesture(width: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { value in
                model.updateRange(
                    start: model.rangeStart,
                    end: time(for: value.location.x, width: width)
                )
            }
    }

    private func xPosition(for time: Double, width: Double) -> Double {
        guard model.duration > 0 else { return 0 }
        return min(max(time / model.duration, 0), 1) * width
    }

    private func time(for xPosition: Double, width: Double) -> Double {
        guard model.duration > 0 else { return 0 }
        return min(max(xPosition / width, 0), 1) * model.duration
    }
}
