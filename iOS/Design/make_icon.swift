// Renders the Conductor app icon (1024×1024, opaque) with CoreGraphics.
//   swift iOS/Design/make_icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                         CGFloat(hex & 0xFF) / 255, a])!
}
func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> UInt32 {
    func ch(_ v: UInt32, _ s: UInt32) -> CGFloat { CGFloat((v >> s) & 0xFF) }
    let r = ch(a, 16) + (ch(b, 16) - ch(a, 16)) * t, g = ch(a, 8) + (ch(b, 8) - ch(a, 8)) * t, bl = ch(a, 0) + (ch(b, 0) - ch(a, 0)) * t
    return (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(bl)
}

// Background: deep charcoal radial gradient.
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x2B2F3A), rgb(0x0A0B0F)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(bg, startCenter: CGPoint(x: S * 0.5, y: S * 0.62), startRadius: 0,
                       endCenter: CGPoint(x: S * 0.5, y: S * 0.5), endRadius: S * 0.78, options: [.drawsAfterEndLocation])

// 4×4 pad grid (row 0 = bottom, CoreGraphics origin is bottom-left).
let pad: CGFloat = 170, gap: CGFloat = 26, radius: CGFloat = 36
let grid = pad * 4 + gap * 3
let x0 = (S - grid) / 2, y0 = (S - grid) / 2

// Lit pads: a rising staircase (amber → coral) plus two teal "drum" hits.
let amber: UInt32 = 0xFFB01F, coral: UInt32 = 0xFF4566, teal: UInt32 = 0x36D6C8
var lit: [String: UInt32] = [:]
for i in 0..<4 { lit["\(i),\(i)"] = mix(amber, coral, CGFloat(i) / 3) }
lit["2,0"] = teal
lit["0,2"] = teal

func padPath(_ c: Int, _ r: Int, inset: CGFloat = 0) -> CGPath {
    let rect = CGRect(x: x0 + CGFloat(c) * (pad + gap) + inset, y: y0 + CGFloat(r) * (pad + gap) + inset,
                      width: pad - inset * 2, height: pad - inset * 2)
    return CGPath(roundedRect: rect, cornerWidth: radius - inset, cornerHeight: radius - inset, transform: nil)
}

for r in 0..<4 {
    for c in 0..<4 {
        let path = padPath(c, r)
        let box = path.boundingBox
        if let hex = lit["\(c),\(r)"] {
            // Glow behind the lit pad.
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 70, color: rgb(hex, 0.85))
            ctx.addPath(path); ctx.setFillColor(rgb(hex)); ctx.fillPath()
            ctx.restoreGState()
            // Lit face: brighter at the top, like a backlit pad.
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            let face = CGGradient(colorsSpace: cs, colors: [rgb(mix(hex, 0xFFFFFF, 0.28)), rgb(hex), rgb(mix(hex, 0x000000, 0.12))] as CFArray,
                                  locations: [0, 0.55, 1])!
            ctx.drawLinearGradient(face, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
            ctx.restoreGState()
            // Inner highlight rim.
            ctx.addPath(padPath(c, r, inset: 3)); ctx.setStrokeColor(rgb(0xFFFFFF, 0.35)); ctx.setLineWidth(3); ctx.strokePath()
        } else {
            // Unlit pad: dark rubber with a faint top sheen.
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            let face = CGGradient(colorsSpace: cs, colors: [rgb(0x2E323C), rgb(0x1C1F26)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(face, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
            ctx.restoreGState()
            ctx.addPath(padPath(c, r, inset: 1.5)); ctx.setStrokeColor(rgb(0xFFFFFF, 0.07)); ctx.setLineWidth(3); ctx.strokePath()
        }
    }
}

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
