// Renders the Jarvis app icon (orb on dark) as PNGs for the PWA.
import AppKit

func render(_ size: CGFloat, to path: String) {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let bg = NSColor(red: 0.02, green: 0.035, blue: 0.06, alpha: 1)
    bg.setFill()
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let c = CGPoint(x: size / 2, y: size / 2)
    let cyan = NSColor(red: 0.31, green: 0.86, blue: 1, alpha: 1)
    let space = CGColorSpaceCreateDeviceRGB()
    let halo = CGGradient(colorsSpace: space, colors: [cyan.withAlphaComponent(0.45).cgColor, cyan.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: c, startRadius: 0, endCenter: c, endRadius: size * 0.46, options: [])
    ctx.setStrokeColor(cyan.withAlphaComponent(0.8).cgColor)
    for (r, w, segs, len) in [(0.36, 0.012, 3, 1.4), (0.30, 0.022, 5, 0.5)] as [(CGFloat, CGFloat, Int, CGFloat)] {
        ctx.setLineWidth(size * w)
        for s in 0..<segs {
            let start = CGFloat(s) * 2 * .pi / CGFloat(segs) + 0.4
            ctx.addArc(center: c, radius: size * r, startAngle: start, endAngle: start + len, clockwise: false)
            ctx.strokePath()
        }
    }
    let core = CGGradient(colorsSpace: space, colors: [NSColor.white.cgColor, cyan.cgColor, cyan.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(core, startCenter: c, startRadius: 0, endCenter: c, endRadius: size * 0.16, options: [])
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let dir = CommandLine.arguments[1]
render(192, to: dir + "/icon-192.png")
render(512, to: dir + "/icon-512.png")
