import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: PlaybackModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            mediaArea
            if model.hasMedia && !model.isFullScreen {
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
            allowedContentTypes: MediaFileSupport.allowedContentTypes,
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
                $0.isFileURL && MediaFileSupport.isSupported($0)
            }) else {
                model.errorMessage =
                    "Drop an MP4, JPG, or PNG media file to open it."
                return false
            }
            model.open(url: url)
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .alert(
            "Unable to Open Media",
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

    private var mediaArea: some View {
        ZStack {
            Color.black

            if model.isVideo {
                VideoSurface(
                    player: model.player,
                    reverseFrame: model.reverseFrame,
                    showsReverseFrame: model.showsReverseFrame,
                    rotationQuarterTurns: model.rotationQuarterTurns
                )
            } else if model.isImage, model.displayedImage != nil {
                ImageSurface(model: model)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 54, weight: .thin))
                        .foregroundStyle(.secondary)

                    Text("Drop media here")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    Button("Open Media…") {
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
            if model.isVideo {
                RangeTimeline(model: model)
            }

            HStack(spacing: 14) {
                if model.isVideo {
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
                }

                Button {
                    model.rotateCounterclockwise()
                } label: {
                    Image(systemName: "rotate.left")
                }
                .help("Rotate 90° Counterclockwise (R)")
                .accessibilityLabel("Rotate 90 Degrees Counterclockwise")

                Button {
                    FullScreenController.shared.toggle()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Full Screen (F)")
                .accessibilityLabel("Full Screen")
                .disabled(!model.hasMedia)

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
                .help("Open Media (⌘O)")
            }

            if model.isVideo {
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
