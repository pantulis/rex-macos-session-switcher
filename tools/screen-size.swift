// Prints the main screen's size in points: WIDTH HEIGHT
import AppKit
let f = NSScreen.screens[0].frame
print(Int(f.width), Int(f.height))
