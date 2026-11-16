// A plain gradient window to photograph the switcher against, so screenshots
// don't pick up whatever is on the desktop. Usage: backdrop X Y WIDTH HEIGHT
// (Cocoa points, origin bottom-left). Runs until killed.
import AppKit

let a = CommandLine.arguments.dropFirst().compactMap { Double($0) }
guard a.count == 4 else { exit(2) }

final class Gradient: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [
            NSColor(red: 0.38, green: 0.55, blue: 0.82, alpha: 1),
            NSColor(red: 0.62, green: 0.45, blue: 0.80, alpha: 1),
            NSColor(red: 0.93, green: 0.58, blue: 0.62, alpha: 1),
        ])!.draw(in: bounds, angle: -35)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(
    contentRect: NSRect(x: a[0], y: a[1], width: a[2], height: a[3]),
    styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = Gradient()
window.hasShadow = false
// Above ordinary windows (so nothing shows through), below the switcher.
window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
window.orderFrontRegardless()
app.run()
