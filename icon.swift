// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Foundation

// Original geometric artwork. No SF Symbols, system icons, or vendor artwork.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let p = CGFloat(pixels)
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let background = NSBezierPath(roundedRect: NSRect(x: p*0.06, y: p*0.06, width: p*0.88, height: p*0.88), xRadius: p*0.20, yRadius: p*0.20)
        NSGradient(starting: NSColor(calibratedRed: 0.39, green: 0.29, blue: 0.88, alpha: 1),
                   ending: NSColor(calibratedRed: 0.18, green: 0.12, blue: 0.44, alpha: 1))!.draw(in: background, angle: 110)
        // Three differently spaced audio modules rest on one continuous desk.
        let modules: [(CGFloat, CGFloat, CGFloat)] = [(0.23, 0.42, 0.32), (0.42, 0.34, 0.29), (0.61, 0.48, 0.26)]
        for (x, y, height) in modules {
            NSColor(calibratedWhite: 1, alpha: 0.95).setFill()
            NSBezierPath(roundedRect: NSRect(x: p*x, y: p*y, width: p*0.15, height: p*height), xRadius: p*0.045, yRadius: p*0.045).fill()
            NSColor(calibratedRed: 0.29, green: 0.21, blue: 0.65, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: p*(x+0.045), y: p*(y+height-0.10), width: p*0.06, height: p*0.055), xRadius: p*0.018, yRadius: p*0.018).fill()
        }
        NSColor(calibratedRed: 0.53, green: 0.95, blue: 0.80, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: p*0.23, y: p*0.23, width: p*0.53, height: p*0.055), xRadius: p*0.0275, yRadius: p*0.0275).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
