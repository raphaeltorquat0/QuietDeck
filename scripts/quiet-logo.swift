// Desenha a marca "Quiet" em PNG transparente para o vídeo de boot. Uso: swift scripts/quiet-logo.swift <saída>
import AppKit

let size = NSSize(width: 1280, height: 800)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 800, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let text = NSAttributedString(string: "Quiet", attributes: [.font: NSFont.systemFont(ofSize: 56, weight: .semibold), .foregroundColor: NSColor.white])
let t = text.size()
text.draw(at: NSPoint(x: (size.width - t.width) / 2, y: (size.height - t.height) / 2))
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
