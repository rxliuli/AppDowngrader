import AppKit
import SwiftUI

@main
struct AppDowngraderApp: App {
    @State private var appState = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Set Dock icon from bundled image, with macOS-standard padding
        let iconPath = resourceBundle.path(forResource: "AppIcon", ofType: "png")
        if let path = iconPath, let src = NSImage(contentsOfFile: path) {
            let canvas = NSSize(width: 1024, height: 1024)
            let inset: CGFloat = 100 // padding around icon
            let icon = NSImage(size: canvas)
            icon.lockFocus()
            src.draw(
                in: NSRect(x: inset, y: inset,
                           width: canvas.width - inset * 2,
                           height: canvas.height - inset * 2),
                from: .zero, operation: .sourceOver, fraction: 1.0
            )
            icon.unlockFocus()
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 700, minHeight: 500)
        }
        .commands {
            CommandGroup(after: .help) {
                Button("Open Log Folder") {
                    Logger.shared.revealInFinder()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}
