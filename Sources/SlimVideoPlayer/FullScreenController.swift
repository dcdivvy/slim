import AppKit

@MainActor
final class FullScreenController {
    static let shared = FullScreenController()
    static let didEnterNotification = Notification.Name(
        "SlimVideoPlayerDidEnterFullScreen"
    )
    static let didExitNotification = Notification.Name(
        "SlimVideoPlayerDidExitFullScreen"
    )

    private struct WindowState {
        let frame: NSRect
        let styleMask: NSWindow.StyleMask
        let level: NSWindow.Level
        let collectionBehavior: NSWindow.CollectionBehavior
        let presentationOptions: NSApplication.PresentationOptions
    }

    private weak var window: NSWindow?
    private var originalState: WindowState?
    private var keyMonitor: Any?

    var isFullScreen: Bool {
        originalState != nil
    }

    func toggle(window requestedWindow: NSWindow? = nil) {
        if isFullScreen {
            exit()
        } else {
            enter(window: requestedWindow)
        }
    }

    func enter(window requestedWindow: NSWindow? = nil) {
        guard !isFullScreen,
              let targetWindow = requestedWindow
                ?? NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible }),
              let screen = targetWindow.screen ?? NSScreen.main else {
            return
        }

        window = targetWindow
        originalState = WindowState(
            frame: targetWindow.frame,
            styleMask: targetWindow.styleMask,
            level: targetWindow.level,
            collectionBehavior: targetWindow.collectionBehavior,
            presentationOptions: NSApp.presentationOptions
        )

        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        targetWindow.styleMask = [.borderless]
        targetWindow.collectionBehavior.insert(.fullScreenPrimary)
        targetWindow.level = .normal
        targetWindow.setFrame(screen.frame, display: true, animate: true)
        targetWindow.makeKeyAndOrderFront(nil)
        installExitKeyMonitor()

        NotificationCenter.default.post(
            name: Self.didEnterNotification,
            object: targetWindow
        )
    }

    func exit() {
        guard let originalState else { return }
        removeExitKeyMonitor()

        NSApp.presentationOptions = originalState.presentationOptions
        if let window {
            window.styleMask = originalState.styleMask
            window.collectionBehavior = originalState.collectionBehavior
            window.level = originalState.level
            window.setFrame(originalState.frame, display: true, animate: true)
            window.makeKeyAndOrderFront(nil)
        }

        self.originalState = nil
        let restoredWindow = window
        window = nil
        NotificationCenter.default.post(
            name: Self.didExitNotification,
            object: restoredWindow
        )
    }

    private func installExitKeyMonitor() {
        removeExitKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }

            let isEscape = event.keyCode == 53
            let modifiers = event.modifierFlags.intersection(
                .deviceIndependentFlagsMask
            )
            let isFullScreenShortcut =
                event.charactersIgnoringModifiers?.lowercased() == "f"
                && modifiers.contains([.command, .control])

            guard isEscape || isFullScreenShortcut else { return event }
            self.exit()
            return nil
        }
    }

    private func removeExitKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
