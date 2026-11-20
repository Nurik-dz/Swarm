import AppKit
import CoreGraphics

// Swarm's icon: a swarm of dots that tightens into a download arrow.
// Apple's macOS squircle (superellipse n=5, 824 on 1024), drawn in Display P3.
// usage: make_icon <out.png> <variant a|b> [size]

let args = CommandLine.arguments
let out = args[1]
let variant = args.count > 2 ? args[2] : "a"
let S: CGFloat = 1024

func p3(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [r, g, b, 1])!
}

let palettes: [String: (top: CGColor, bottom: CGColor, glow: CGColor)] = [
    "a": (p3(0.36, 0.42, 1.00),
          p3(0.12, 0.10, 0.55),
          p3(0.55, 0.80, 1.00)),
    "b": (p3(0.16, 0.86, 0.70),
          p3(0.02, 0.34, 0.46),
          p3(0.70, 1.00, 0.85)),
]
let pal = palettes[variant] ?? palettes["a"]!

let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(tile)

// Drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape)
ctx.setFillColor(pal.bottom)
ctx.fillPath()
ctx.restoreGState()

// Background gradient.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let grad = CGGradient(colorsSpace: cs, colors: [pal.top, pal.bottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// Soft glow behind the arrow.
let glow = CGGradient(colorsSpace: cs, colors: [pal.glow.copy(alpha: 0.55)!, pal.glow.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 470), endRadius: 420, options: [])

// The arrow (y up). Shaft and head.
let arrow = CGMutablePath()
let shaftW: CGFloat = 150, headW: CGFloat = 430
let topY: CGFloat = 800, headY: CGFloat = 470, tipY: CGFloat = 235
arrow.move(to: CGPoint(x: 512 - shaftW / 2, y: topY))
arrow.addLine(to: CGPoint(x: 512 + shaftW / 2, y: topY))
arrow.addLine(to: CGPoint(x: 512 + shaftW / 2, y: headY))
arrow.addLine(to: CGPoint(x: 512 + headW / 2, y: headY))
arrow.addLine(to: CGPoint(x: 512, y: tipY))
arrow.addLine(to: CGPoint(x: 512 - headW / 2, y: headY))
arrow.addLine(to: CGPoint(x: 512 - shaftW / 2, y: headY))
arrow.closeSubpath()

func distanceToArrow(_ p: CGPoint) -> CGFloat {
    if arrow.contains(p) { return 0 }
    var best = CGFloat.greatestFiniteMagnitude
    let pts: [CGPoint] = [
        CGPoint(x: 512 - shaftW / 2, y: topY), CGPoint(x: 512 + shaftW / 2, y: topY),
        CGPoint(x: 512 + shaftW / 2, y: headY), CGPoint(x: 512 + headW / 2, y: headY),
        CGPoint(x: 512, y: tipY), CGPoint(x: 512 - headW / 2, y: headY),
        CGPoint(x: 512 - shaftW / 2, y: headY), CGPoint(x: 512 - shaftW / 2, y: topY),
    ]
    for i in 0..<(pts.count - 1) {
        let a = pts[i], b = pts[i + 1]
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / (ab.x * ab.x + ab.y * ab.y)))
        let q = CGPoint(x: a.x + ab.x * t, y: a.y + ab.y * t)
        best = min(best, hypot(p.x - q.x, p.y - q.y))
    }
    return best
}

// Dots on a hexagonal grid: full and bright inside the arrow, smaller and
// fainter the further out they are (the swarm).
let step: CGFloat = 46
var row = 0
var y: CGFloat = 130
while y < 900 {
    let offset = row % 2 == 0 ? 0 : step / 2
    var x: CGFloat = 120 + offset
    while x < 910 {
        let p = CGPoint(x: x, y: y)
        if shape.contains(p) {
            let d = distanceToArrow(p)
            let inside = d == 0
            let r: CGFloat = inside ? 17 : 15 * exp(-d / 80)
            let alpha: CGFloat = inside ? 1 : 0.85 * exp(-d / 110)
            if r > 2.2 && alpha > 0.04 {
                ctx.setFillColor(CGColor(gray: 1, alpha: alpha))
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
        }
        x += step
    }
    y += step * 0.866
    row += 1
}

// Top light.
let shine = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
ctx.restoreGState()

// Fine rim.
ctx.addPath(shape)
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
ctx.setLineWidth(3)
ctx.strokePath()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
