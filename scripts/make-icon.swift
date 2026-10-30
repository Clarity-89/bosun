// The source of Resources/AppIcon.icns: an anchor on a sea-blue squircle,
// drawn at every size an icns holds. Run after changing the drawing and
// commit the icns:  swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let canvas: CGFloat = 1024

/// Everything in 1024-point coordinates, y up; the context scales.
func draw(in context: CGContext, pixels: Int) {
    context.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    // Apple's macOS template: the shape fills 824 of 1024 points; the
    // system draws the shadow and, on macOS 26, the glass.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.addPath(shape)
    context.clip()
    let colors = [CGColor(red: 0.18, green: 0.46, blue: 0.82, alpha: 1), CGColor(red: 0.04, green: 0.16, blue: 0.38, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: plate.maxY), end: CGPoint(x: 512, y: plate.minY), options: [])

    // Strokes thicken at thumbnail sizes, where a hairline would vanish.
    let bold: CGFloat = pixels <= 32 ? 1.6 : pixels <= 128 ? 1.2 : 1
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: CGColor(gray: 0, alpha: 0.35))
    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.setLineCap(.round)

    // Ring, shank, stock.
    context.setLineWidth(40 * bold)
    context.strokeEllipse(in: CGRect(x: 512 - 62, y: 745 - 62, width: 124, height: 124))
    context.setLineWidth(56 * bold)
    context.move(to: CGPoint(x: 512, y: 683))
    context.addLine(to: CGPoint(x: 512, y: 262))
    context.strokePath()
    context.setLineWidth(48 * bold)
    context.move(to: CGPoint(x: 362, y: 628))
    context.addLine(to: CGPoint(x: 662, y: 628))
    context.strokePath()

    // Arms: an arc under the shank's foot, a fluke at each end.
    context.setLineWidth(56 * bold)
    context.addArc(center: CGPoint(x: 512, y: 445), radius: 185, startAngle: .pi * 200 / 180, endAngle: .pi * 340 / 180, clockwise: false)
    context.strokePath()
    for side: CGFloat in [-1, 1] {
        let x = 512 + side * 174
        context.move(to: CGPoint(x: x - side * 12, y: 505))
        context.addLine(to: CGPoint(x: x - side * 72, y: 386))
        context.addLine(to: CGPoint(x: x + side * 38, y: 380))
        context.closePath()
        context.fillPath()
    }
}

func png(pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(in: context, pixels: pixels)
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
try FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
