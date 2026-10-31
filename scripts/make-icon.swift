// Desenha o ícone do app em App/Resources/Assets.xcassets/AppIcon.appiconset.
// Uso: swift scripts/make-icon.swift   Traços próprios: SF Symbols não podem ir em ícone de app.
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Grade de ícone do macOS: tela 1024, squircle de 824, mesmo fundo de estúdio do Quietbar.
    let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 22 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(white: 0.80, alpha: 1), NSColor(white: 0.93, alpha: 1), NSColor(white: 0.985, alpha: 1)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: tile, angle: 90)

    // Console: corpo, tela e os dois analógicos.
    NSColor(white: 0.13, alpha: 1).setFill()
    NSBezierPath(roundedRect: r(170, 365, 684, 294), xRadius: 105 * s, yRadius: 105 * s).fill()
    NSColor(calibratedRed: 0.28, green: 0.55, blue: 0.95, alpha: 1).setFill()
    NSBezierPath(roundedRect: r(345, 410, 334, 204), xRadius: 18 * s, yRadius: 18 * s).fill()
    NSColor(white: 0.42, alpha: 1).setFill()
    NSBezierPath(ovalIn: r(226, 530, 64, 64)).fill()
    NSBezierPath(ovalIn: r(734, 530, 64, 64)).fill()
    NSColor(white: 0.3, alpha: 1).setFill()
    NSBezierPath(roundedRect: r(226, 430, 64, 64), xRadius: 12 * s, yRadius: 12 * s).fill()
    NSBezierPath(roundedRect: r(734, 430, 64, 64), xRadius: 12 * s, yRadius: 12 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "App/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try render(pt * scale).write(to: dir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("Contents.json"))
