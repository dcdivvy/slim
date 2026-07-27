import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }
}

@main
struct SlimVideoPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = PlaybackModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Media…") {
                    model.isFileImporterPresented = true
                }
                .keyboardShortcut("o")
            }

            CommandMenu("Playback") {
                Button(model.isPlaying ? "Pause" : "Play") {
                    model.togglePlayback()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!model.isVideo)

                Button("Previous Frame") {
                    model.stepFrame(direction: -1)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!model.canStepFrames)

                Button("Next Frame") {
                    model.stepFrame(direction: 1)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!model.canStepFrames)

                Divider()

                Button("Repeat Mode: \(model.repeatMode.title)") {
                    model.cycleRepeatMode()
                }
                .disabled(!model.isVideo)
            }

            CommandMenu("View") {
                Button("Rotate") {
                    model.rotateCounterclockwise()
                }
                .keyboardShortcut("r", modifiers: [])
                .disabled(!model.hasMedia)

                Button(model.isFullScreen ? "Exit Full Screen" : "Full Screen") {
                    FullScreenController.shared.toggle()
                }
                .keyboardShortcut("f", modifiers: [])
                .disabled(!model.hasMedia)

                Divider()

                Button("Zoom In") {
                    model.zoomImageIn()
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!model.isImage)

                Button("Zoom Out") {
                    model.zoomImageOut()
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!model.isImage)

                Button("Actual Size / Zoom to Fit") {
                    model.toggleImageZoomFitOrActual()
                }
                .keyboardShortcut(".", modifiers: [])
                .disabled(!model.isImage)
            }
        }
    }
}
