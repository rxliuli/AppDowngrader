import AppKit
import SwiftUI

@main
struct AppDowngraderApp: App {
    @State private var appState = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Set Dock icon from SF Symbol
        if let icon = NSImage(
            systemSymbolName: "arrow.down.app.fill",
            accessibilityDescription: "AppDowngrader"
        ) {
            icon.isTemplate = false
            let size = NSSize(width: 128, height: 128)
            let colored = NSImage(size: size)
            colored.lockFocus()
            NSColor.systemBlue.setFill()
            NSBezierPath(
                roundedRect: NSRect(origin: .zero, size: size),
                xRadius: 28, yRadius: 28
            ).fill()
            NSColor.white.setFill()
            icon.draw(
                in: NSRect(x: 20, y: 20, width: 88, height: 88),
                from: .zero, operation: .destinationIn, fraction: 1.0
            )
            colored.unlockFocus()
            NSApplication.shared.applicationIconImage = colored
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 700, minHeight: 500)
        }
    }
}
