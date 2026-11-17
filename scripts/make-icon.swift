// Draws the app icon (a white broom with sparkles on a fresh gradient) into an .iconset.
//   scripts/make-icon.sh  (writes Resources/AppIcon.icns)
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    let s = CGFloat(px)
    cg.translateBy(x: 0, y: s); cg.scaleBy(x: 1, y: -1)      // y down, like the broom path

    // macOS icon grid: 824/1024 rounded square, centered.
    let inset = s * 100 / 1024
    let box = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = CGPath(roundedRect: box, cornerWidth: box.width * 0.225, cornerHeight: box.width * 0.225, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    cg.addPath(squircle); cg.setFillColor(NSColor.black.cgColor); cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(squircle); cg.clip()
    let colors = [NSColor(srgbRed: 0.20, green: 0.83, blue: 0.60, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.05, green: 0.55, blue: 0.86, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: box.minX, y: box.minY), end: CGPoint(x: box.maxX, y: box.maxY), options: [])

    // Broom
    let broomRect = box.insetBy(dx: box.width * 0.07, dy: box.height * 0.07).offsetBy(dx: box.width * 0.05, dy: box.height * 0.01)
    cg.setShadow(offset: CGSize(width: 0, height: s * 0.008), blur: s * 0.02, color: NSColor.black.withAlphaComponent(0.22).cgColor)
    cg.addPath(BroomPath.path(in: broomRect))
    cg.setFillColor(NSColor.white.cgColor)
    cg.fillPath(using: .evenOdd)
    // Sparkles where it swept
    cg.setShadow(offset: .zero, blur: 0, color: nil)
    cg.setFillColor(NSColor(srgbRed: 1, green: 0.95, blue: 0.55, alpha: 1).cgColor)
    for (x, y, r) in [(0.24, 0.30, 0.075), (0.36, 0.17, 0.045), (0.17, 0.48, 0.04)] {
        cg.addPath(BroomPath.sparkle(at: CGPoint(x: box.minX + box.width * x, y: box.minY + box.height * y), size: box.width * r))
        cg.fillPath()
    }
    cg.restoreGState()
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
print("wrote \(out)")
