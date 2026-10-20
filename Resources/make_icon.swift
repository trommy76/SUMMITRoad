import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Black rounded-square tile with standard macOS margin
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSColor.black.setFill(); tile.fill()
ctx.saveGState(); tile.addClip()

// Grey road receding to a horizon
let road = NSBezierPath()
road.move(to: NSPoint(x: 60, y: 100)); road.line(to: NSPoint(x: 964, y: 100))
road.line(to: NSPoint(x: 560, y: 600)); road.line(to: NSPoint(x: 464, y: 600)); road.close()
NSColor(white: 0.36, alpha: 1).setFill(); road.fill()

// Edge lines
NSColor(white: 0.55, alpha: 1).setStroke()
for (a, b) in [(NSPoint(x: 140, y: 100), NSPoint(x: 476, y: 600)), (NSPoint(x: 884, y: 100), NSPoint(x: 548, y: 600))] {
    let p = NSBezierPath(); p.move(to: a); p.line(to: b); p.lineWidth = 8; p.stroke()
}
// Dashed centre line, dashes shrinking with distance
NSColor(white: 0.78, alpha: 1).setFill()
var y: CGFloat = 110
var h: CGFloat = 70
while y < 590 {
    let t = (y - 100) / 500
    let w = 26 * (1 - t) + 4
    let d = NSBezierPath(rect: NSRect(x: 512 - w / 2, y: y, width: w, height: h))
    d.fill()
    y += h * 1.9
    h *= 0.78
}
ctx.restoreGState()

// Bike (side view, light grey) on the road
NSColor(white: 0.93, alpha: 1).setStroke()
func line(_ pts: [NSPoint], _ w: CGFloat = 20) {
    let p = NSBezierPath(); p.move(to: pts[0]); for q in pts.dropFirst() { p.line(to: q) }
    p.lineWidth = w; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke()
}
func wheel(_ c: NSPoint, _ r: CGFloat) {
    let p = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    p.lineWidth = 20; p.stroke()
}
let R = NSPoint(x: 352, y: 300), F = NSPoint(x: 672, y: 300)
let BB = NSPoint(x: 500, y: 285), S1 = NSPoint(x: 448, y: 450)
let H = NSPoint(x: 622, y: 460), HB = NSPoint(x: 636, y: 410)
wheel(R, 92); wheel(F, 92)
line([R, BB, S1, R])           // rear triangle
line([S1, H])                  // top tube
line([BB, HB])                 // down tube
line([HB, F])                  // fork
line([H, HB], 24)              // head tube
line([S1, NSPoint(x: 440, y: 490)])
line([NSPoint(x: 400, y: 495), NSPoint(x: 485, y: 495)], 24)   // saddle
line([H, NSPoint(x: 612, y: 515), NSPoint(x: 668, y: 505), NSPoint(x: 684, y: 470)], 18) // bars
line([BB, NSPoint(x: 470, y: 235)], 14)  // crank
line([BB, NSPoint(x: 530, y: 335)], 14)

// Wordmark in the sky above the road
let word = NSMutableAttributedString()
let kern: NSNumber = 3
word.append(NSAttributedString(string: "SUMMIT", attributes: [
    .font: NSFont.systemFont(ofSize: 92, weight: .heavy), .foregroundColor: NSColor(red: 0.62, green: 0.32, blue: 0.95, alpha: 1), .kern: kern]))
word.append(NSAttributedString(string: "ROAD", attributes: [
    .font: NSFont.systemFont(ofSize: 92, weight: .light), .foregroundColor: NSColor(white: 0.75, alpha: 1), .kern: kern]))
let ws = word.size()
word.draw(at: NSPoint(x: (S - ws.width) / 2, y: 705))

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
