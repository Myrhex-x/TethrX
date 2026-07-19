// Render a 1024x1024 monochrome ">_" app icon using CoreGraphics only (no AppKit).
//   swift tools/make-icon.swift <output.png>
import CoreGraphics
import ImageIO
import Foundation

let px = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

// near-black background (#0a0a0a)
ctx.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))

ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// ">" chevron (CG origin is bottom-left)
ctx.setLineWidth(94)
ctx.move(to: CGPoint(x: 372, y: 686))
ctx.addLine(to: CGPoint(x: 628, y: 520))
ctx.addLine(to: CGPoint(x: 372, y: 354))
ctx.strokePath()

// "_" underscore
ctx.setLineWidth(74)
ctx.move(to: CGPoint(x: 470, y: 300))
ctx.addLine(to: CGPoint(x: 712, y: 300))
ctx.strokePath()

guard let image = ctx.makeImage() else { exit(1) }
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(CommandLine.arguments[1])")
