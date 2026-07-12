import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: PlaybackModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            videoArea
            if model.hasVideo && !model.isFullScreen {
                controls
            }
        }
        .background(.black)
        .onReceive(
            NotificationCenter.default.publisher(
                for: FullScreenController.didEnterNotification
            )
        ) { _ in
            model.isFullScreen = true
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: FullScreenController.didExitNotification
            )
        ) { _ in
            model.isFullScreen = false
        }
        .fileImporter(
            isPresented: $model.isFileImporterPresented,
            allowedContentTypes: [.mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.open(url: url)
                }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: {
                $0.isFileURL && $0.pathExtension.lowercased() == "mp4"
            }) else {
                model.errorMessage = "Drop an MP4 video file to open it."
                return false
            }
            model.open(url: url)
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .alert(
            "Unable to Open Video",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var videoArea: some View {
        ZStack {
            Color.black

            if model.hasVideo {
                VideoSurface(
                    player: model.player,
                    reverseFrame: model.reverseFrame,
                    showsReverseFrame: model.showsReverseFrame,
                    rotationQuarterTurns: model.rotationQuarterTurns
                )
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 54, weight: .thin))
                        .foregroundStyle(.secondary)

                    Text("Drop an MP4 video here")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    Button("Open Video…") {
                        model.isFileImporterPresented = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 4, dash: [10, 6]))
                    .background(.tint.opacity(0.12))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            RangeTimeline(model: model)
                .disabled(!model.hasVideo)

            HStack(spacing: 14) {
                Button {
                    model.stepFrame(direction: -1)
                } label: {
                    Image(systemName: "backward.frame.fill")
                }
                .help("Previous Frame (Left Arrow)")
                .disabled(!model.canStepFrames)

                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderedProminent)
                .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
                .disabled(!model.hasVideo)

                Button {
                    model.stepFrame(direction: 1)
                } label: {
                    Image(systemName: "forward.frame.fill")
                }
                .help("Next Frame (Right Arrow)")
                .disabled(!model.canStepFrames)

                Divider()
                    .frame(height: 20)

                Button {
                    model.cycleRepeatMode()
                } label: {
                    Image(systemName: repeatButtonIcon)
                        .foregroundStyle(.black)
                }
                .buttonStyle(.borderedProminent)
                .tint(repeatButtonColor)
                .help("Repeat Mode: \(model.repeatMode.title)")
                .accessibilityLabel("Repeat Mode: \(model.repeatMode.title)")
                .disabled(!model.hasVideo)

                Button("Set Start") {
                    model.setRangeStartToCurrentTime()
                }
                .help("Set Range Start to Current Position")
                .disabled(!model.canSetRangeStart)

                Button("Set End") {
                    model.setRangeEndToCurrentTime()
                }
                .help("Set Range End to Current Position")
                .disabled(!model.canSetRangeEnd)

                Button {
                    model.rotateCounterclockwise()
                } label: {
                    Image(systemName: "rotate.left")
                }
                .help("Rotate 90° Counterclockwise")
                .accessibilityLabel("Rotate 90 Degrees Counterclockwise")
                .disabled(!model.hasVideo)

                Button {
                    FullScreenController.shared.toggle()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Full Screen (⌃⌘F)")
                .accessibilityLabel("Full Screen")
                .disabled(!model.hasVideo)

                Spacer()

                if let fileName = model.fileName {
                    Text(fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }

                Button {
                    model.isFileImporterPresented = true
                } label: {
                    Image(systemName: "folder")
                }
                .help("Open Video (⌘O)")
            }

            HStack(spacing: 18) {
                metric("Elapsed", model.formatTime(model.currentTime))
                metric("Frame", "\(model.currentFrame)")
                metric("Remaining", model.formatTime(model.remainingTime))
                metric("Duration", model.formatTime(model.duration))

                Spacer()

                Text(
                    "Range \(model.formatTime(model.rangeStart)) – "
                        + model.formatTime(model.rangeEnd)
                )
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
        }
    }

    private var repeatButtonIcon: String {
        switch model.repeatMode {
        case .off:
            "octagon.fill"
        case .fromStart:
            "repeat"
        case .bounce:
            "arrow.left.and.right"
        }
    }

    private var repeatButtonColor: Color {
        switch model.repeatMode {
        case .off:
            .gray
        case .fromStart:
            .green
        case .bounce:
            .orange
        }
    }
}
