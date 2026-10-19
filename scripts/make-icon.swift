// Renders the Beam app icon: swift scripts/make-icon.swift <output.png>
// A flat rounded play shape with two cast arcs "beaming" out of it, on a dark tile.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let context = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt squircle centred in the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Soft drop shadow under the tile.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
context.addPath(tilePath)
context.setFillColor(NSColor.black.cgColor)
context.fillPath()
context.restoreGState()

// Flat dark background.
context.addPath(tilePath)
context.setFillColor(CGColor(srgbRed: 0.09, green: 0.09, blue: 0.12, alpha: 1))
context.fillPath()
let accent = CGColor(srgbRed: 0.45, green: 0.42, blue: 1.0, alpha: 1)

// Rounded play triangle.
func roundedTriangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
    path.addArc(tangent1End: b, tangent2End: c, radius: radius)
    path.addArc(tangent1End: c, tangent2End: a, radius: radius)
    path.addArc(tangent1End: a, tangent2End: b, radius: radius)
    path.closeSubpath()
    return path
}
let play = roundedTriangle(CGPoint(x: 300, y: 300), CGPoint(x: 300, y: 724), CGPoint(x: 640, y: 512), radius: 60)
context.addPath(play)
context.setFillColor(accent)
context.fillPath()

// Two cast arcs radiating from the tip of the play shape.
context.setLineCap(.round)
for (index, radius) in [CGFloat(110), 190].enumerated() {
    let arc = CGMutablePath()
    arc.addArc(center: CGPoint(x: 590, y: 512), radius: radius,
               startAngle: -.pi / 4, endAngle: .pi / 4, clockwise: false)
    context.setLineWidth(44)
    context.addPath(arc)
    context.setStrokeColor(accent.copy(alpha: index == 0 ? 1 : 0.55)!)
    context.strokePath()
}

// Hairline highlight on the tile edge.
context.addPath(tilePath)
context.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
context.setLineWidth(3)
context.strokePath()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
