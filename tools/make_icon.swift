// Draws the PocketSynth app icon: rounded waveform bars in the app's accent teal on
// black. Usage: swift make_icon.swift <out.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
// No alpha: iOS app icons must be opaque.
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Theme.accent = (0.30, 0.85, 0.78)
ctx.setFillColor(CGColor(srgbRed: 0.30, green: 0.85, blue: 0.78, alpha: 1))

// Bar heights as a fraction of the tallest bar; uneven, like a real waveform.
let heights: [CGFloat] = [0.20, 0.42, 0.68, 0.48, 1.00, 0.74, 0.40, 0.60, 0.26]
let barWidth: CGFloat = 56
let gap: CGFloat = 30
let maxHeight: CGFloat = 600
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
let x0 = (CGFloat(size) - total) / 2
let mid = CGFloat(size) / 2

for (i, h) in heights.enumerated() {
    let height = max(barWidth, maxHeight * h)
    let rect = CGRect(x: x0 + CGFloat(i) * (barWidth + gap), y: mid - height / 2,
                      width: barWidth, height: height)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
}
ctx.fillPath()

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: out)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("couldn't write \(out)") }
print("wrote \(out)")
