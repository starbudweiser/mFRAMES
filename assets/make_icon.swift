// Dessine l'icône de mFRAMES : carré arrondi turquoise, cadre blanc avec triangle de lecture, épingle de retour orange.
import AppKit
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "mFRAMES_1024.png"
let s: CGFloat = 1024
let img = NSImage(size: NSSize(width: s, height: s))
img.lockFocus()
let r = NSRect(x: 40, y: 40, width: s - 80, height: s - 80)
let bg = NSBezierPath(roundedRect: r, xRadius: r.width * 0.227, yRadius: r.width * 0.227)
NSGradient(starting: NSColor(srgbRed: 0.37, green: 0.92, blue: 0.83, alpha: 1), ending: NSColor(srgbRed: 0.05, green: 0.58, blue: 0.53, alpha: 1))!.draw(in: bg, angle: -50)
let frame = NSBezierPath(roundedRect: NSRect(x: 220, y: 300, width: 584, height: 424), xRadius: 78, yRadius: 78)
frame.lineWidth = 46; NSColor.white.setStroke(); frame.stroke()
let play = NSBezierPath(); play.move(to: NSPoint(x: 462, y: 440)); play.line(to: NSPoint(x: 462, y: 584)); play.line(to: NSPoint(x: 590, y: 512)); play.close()
NSColor.white.setFill(); play.fill()
NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 676, y: 618, width: 150, height: 150)).fill()
NSColor.white.setStroke(); let ring = NSBezierPath(ovalIn: NSRect(x: 676, y: 618, width: 150, height: 150)); ring.lineWidth = 16; ring.stroke()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
