#!/usr/bin/env swift
//
// make-icon.swift — draws ShadowPcAdvanced's app icon and builds the .icns.
//
//   swift Scripts/make-icon.swift [--preview <dir>]
//
// Outputs
//   Design/AppIcon-1024.png        1024 px master (not bundled)
//   App/Resources/AppIcon.icns     what CFBundleIconFile points at
//   <dir>/AppIcon-preview.png      only with --preview: small sizes blown up
//
// Every iconset size is rendered natively (not downsampled from the master) so
// the glyph can be simplified and pixel-snapped at 16/32 px.  All geometry is in
// "design units" of a 1024×1024 canvas with a top-left origin.
//
// Original artwork: a monitor with a crescent on its screen, casting a hard
// neon "funky shadow".  Not derived from any vendor's logo.
//
// Note: expressions are deliberately split into typed lets — long arithmetic
// one-liners have hung the Swift 5.9 type checker on the build machine.

import AppKit
import CoreGraphics
import ImageIO

// MARK: - Helpers

let sRGB: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func rgba(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> CGColor {
    let r: CGFloat = CGFloat((hex >> 16) & 0xFF) / 255.0
    let g: CGFloat = CGFloat((hex >> 8) & 0xFF) / 255.0
    let b: CGFloat = CGFloat(hex & 0xFF) / 255.0
    let parts: [CGFloat] = [r, g, b, alpha]
    return CGColor(colorSpace: sRGB, components: parts)!
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    return CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)!
}

let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

func fillLinear(_ ctx: CGContext, _ g: CGGradient, from: CGPoint, to: CGPoint) {
    ctx.drawLinearGradient(g, start: from, end: to, options: extend)
}

func fillRadial(_ ctx: CGContext, _ g: CGGradient, center: CGPoint, radius: CGFloat) {
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    let limit: CGFloat = min(rect.width, rect.height) / 2.0
    let r: CGFloat = min(radius, limit)
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

/// Apple-style continuous-curvature rounded rectangle ("squircle").
/// Hand-rolled with the well-known three-Bézier-per-corner approximation of the
/// system shape, because `import SwiftUI` does not link under the `swift`
/// script interpreter on this toolchain.  Valid while radius * 1.53 <= side / 2.
func squircle(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    // (along incoming edge, along outgoing edge) in multiples of the radius,
    // measured back from / forward of the sharp corner point.
    let coefficients: [(CGFloat, CGFloat)] = [
        (1.52866483, 0.0),
        (1.08849296, 0.0), (0.86840694, 0.0), (0.63149399, 0.07491139),
        (0.37282383, 0.16905956), (0.16905956, 0.37282383), (0.07491139, 0.63149399),
        (0.0, 0.86840694), (0.0, 1.08849296), (0.0, 1.52866483),
    ]
    // Clockwise in a y-down space: corner point, incoming direction, outgoing direction.
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
    ]
    let path = CGMutablePath()
    var started: Bool = false
    for (corner, u, v) in corners {
        var pts: [CGPoint] = []
        for (a, b) in coefficients {
            let back: CGFloat = a * radius
            let forward: CGFloat = b * radius
            let x: CGFloat = corner.x - back * u.dx + forward * v.dx
            let y: CGFloat = corner.y - back * u.dy + forward * v.dy
            pts.append(CGPoint(x: x, y: y))
        }
        if started {
            path.addLine(to: pts[0])
        } else {
            path.move(to: pts[0])
            started = true
        }
        path.addCurve(to: pts[3], control1: pts[1], control2: pts[2])
        path.addCurve(to: pts[6], control1: pts[4], control2: pts[5])
        path.addCurve(to: pts[9], control1: pts[7], control2: pts[8])
    }
    path.closeSubpath()
    return path
}

// MARK: - Drawing

func drawIcon(_ ctx: CGContext, size: CGFloat) {
    let s: CGFloat = size / 1024.0          // design units → pixels
    let px: CGFloat = 1024.0 / size         // one pixel, in design units
    let small: Bool = size <= 32            // 16 and 32 px: simplified glyph
    let tiny: Bool = size <= 16             // 16 px: crescent placed on the pixel grid

    func snap(_ v: CGFloat) -> CGFloat {
        let n: CGFloat = (v / px).rounded()
        return n * px
    }

    ctx.saveGState()
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: s, y: -s)

    // ---- Body ---------------------------------------------------------------
    // 824 of 1024 at full size.  Like the system icons, the body is snapped to
    // whole pixels at small sizes and grows to 14/16 (28/32) px at 16 and 32 px.
    let bodyMin: CGFloat = small ? 64 : snap(100)
    let bodyMax: CGFloat = small ? 960 : snap(924)
    let bodySide: CGFloat = bodyMax - bodyMin
    let bodyRadius: CGFloat = 185.0 * bodySide / 824.0
    let bodyRect = CGRect(x: bodyMin, y: bodyMin, width: bodySide, height: bodySide)
    let bodyPath: CGPath = squircle(bodyRect, bodyRadius)

    // Standard Big Sur drop shadow.  Shadow parameters live in base (pixel)
    // space, which is bottom-left origin: negative height = downwards.
    ctx.saveGState()
    let dropOffset = CGSize(width: 0, height: -12.0 * s)
    let dropBlur: CGFloat = max(28.0 * s, 1.5)
    ctx.setShadow(offset: dropOffset, blur: dropBlur, color: rgba(0x000000, 0.30))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgba(0x1A1140))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    // Top-to-bottom base gradient: indigo → near black.
    let bodyGradient = gradient(
        [rgba(0x46309A), rgba(0x2A1C66), rgba(0x130D30), rgba(0x0A0716)],
        [0.0, 0.35, 0.75, 1.0])
    fillLinear(ctx, bodyGradient, from: CGPoint(x: 512, y: bodyMin), to: CGPoint(x: 512, y: bodyMax))

    // Mood lighting: cool wash top-left, magenta bloom behind the glyph's shadow side.
    let coolGlow = gradient([rgba(0x5B7CFF, 0.30), rgba(0x5B7CFF, 0.0)], [0.0, 1.0])
    fillRadial(ctx, coolGlow, center: CGPoint(x: 290, y: 210), radius: 520)
    let hotGlow = gradient([rgba(0xFF2FD0, 0.26), rgba(0xFF2FD0, 0.0)], [0.0, 1.0])
    fillRadial(ctx, hotGlow, center: CGPoint(x: 690, y: 700), radius: 430)

    // Soft inner highlight: a rim that is bright at the top and fades out.
    ctx.saveGState()
    let rimWidth: CGFloat = max(7.0, px * 1.5)
    ctx.addPath(bodyPath)
    ctx.setLineWidth(rimWidth)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let rimTop: CGFloat = small ? 0.26 : 0.42
    let rimGradient = gradient(
        [rgba(0xFFFFFF, rimTop), rgba(0xFFFFFF, 0.10), rgba(0xFFFFFF, 0.0), rgba(0x000000, 0.25)],
        [0.0, 0.30, 0.60, 1.0])
    fillLinear(ctx, rimGradient, from: CGPoint(x: 512, y: bodyMin), to: CGPoint(x: 512, y: bodyMax))
    ctx.restoreGState()

    // ---- Glyph geometry -----------------------------------------------------
    let monW: CGFloat = small ? 576 : 584
    let monH: CGFloat = small ? 448 : 372
    let neckW: CGFloat = small ? 128 : 104
    let neckH: CGFloat = small ? 64 : 44
    let baseW: CGFloat = small ? 320 : 256
    let baseH: CGFloat = small ? 64 : 28
    let frame: CGFloat = small ? 64 : max(36, px * 2.0)
    let outerR: CGFloat = small ? 72 : 50
    let offset: CGFloat = small ? 64 : max(26, px)

    let glyphW: CGFloat = monW + offset
    let glyphH: CGFloat = monH + neckH + baseH + offset
    let monX: CGFloat = snap(512.0 - glyphW / 2.0)
    let rawTop: CGFloat = 512.0 - glyphH / 2.0
    let monY: CGFloat = snap(rawTop - (small ? 0.0 : 6.0))

    let monRect = CGRect(x: monX, y: monY, width: snap(monW), height: snap(monH))
    let midX: CGFloat = monRect.midX
    let neckX: CGFloat = snap(midX - neckW / 2.0)
    let neckRect = CGRect(x: neckX, y: monRect.maxY - 2.0, width: snap(neckW), height: snap(neckH) + 2.0)
    let baseX: CGFloat = snap(midX - baseW / 2.0)
    let baseRect = CGRect(x: baseX, y: monRect.maxY + snap(neckH), width: snap(baseW), height: snap(baseH))
    let baseR: CGFloat = small ? 0.0 : baseH / 2.0

    let silhouette = CGMutablePath()
    silhouette.addPath(roundedRect(monRect, outerR))
    silhouette.addRect(neckRect)
    silhouette.addPath(roundedRect(baseRect, baseR))

    // ---- The funky shadow: a hard neon offset copy of the glyph -------------
    ctx.saveGState()
    let softOffset = CGSize(width: 0, height: -14.0 * s)
    ctx.setShadow(offset: softOffset, blur: 36.0 * s, color: rgba(0x05020F, 0.55))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.translateBy(x: snap(offset), y: snap(offset))
    ctx.addPath(silhouette)
    ctx.clip()
    let neon = gradient([rgba(0xFF4FD8), rgba(0xC23BFF), rgba(0x6A35FF)], [0.0, 0.55, 1.0])
    let neonStart = CGPoint(x: monRect.maxX, y: monRect.minY)
    let neonEnd = CGPoint(x: monRect.minX, y: baseRect.maxY)
    fillLinear(ctx, neon, from: neonStart, to: neonEnd)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // ---- Monitor ------------------------------------------------------------
    // Stand first (slightly shaded neck), then the bezel on top.
    ctx.saveGState()
    ctx.addRect(neckRect)
    ctx.clip()
    let neckGradient = gradient([rgba(0x9F93D8), rgba(0xD9D2FA)], [0.0, 1.0])
    fillLinear(ctx, neckGradient, from: CGPoint(x: midX, y: neckRect.minY), to: CGPoint(x: midX, y: neckRect.maxY))
    ctx.restoreGState()

    ctx.addPath(roundedRect(baseRect, baseR))
    ctx.setFillColor(rgba(0xF1EDFF))
    ctx.fillPath()

    ctx.saveGState()
    ctx.addPath(roundedRect(monRect, outerR))
    ctx.clip()
    let bezel = gradient([rgba(0xFFFFFF), rgba(0xDCD5FF)], [0.0, 1.0])
    fillLinear(ctx, bezel, from: CGPoint(x: midX, y: monRect.minY), to: CGPoint(x: midX, y: monRect.maxY))
    ctx.restoreGState()

    // ---- Screen -------------------------------------------------------------
    let inset: CGFloat = snap(frame)
    let screenRect = monRect.insetBy(dx: inset, dy: inset)
    let screenR: CGFloat = small ? 0.0 : max(outerR - inset, 10.0)
    ctx.saveGState()
    ctx.addPath(roundedRect(screenRect, screenR))
    ctx.clip()

    let screenGradient = gradient([rgba(0x1B1242), rgba(0x0B0719)], [0.0, 1.0])
    fillLinear(ctx, screenGradient,
               from: CGPoint(x: midX, y: screenRect.minY), to: CGPoint(x: midX, y: screenRect.maxY))

    // Crescent: a disc with an offset bite, lit cyan, glowing.
    // At 16 px the disc is exactly 4 px wide with its edges on pixel boundaries,
    // and the bite opens sideways so what is left reads as a "C", not an "L".
    let moonScale: CGFloat = small ? 0.42 : 0.37
    let moonR: CGFloat = tiny ? px * 2.0 : screenRect.height * moonScale
    let nudgeX: CGFloat = tiny ? px * 0.5 : moonR * 0.10
    let nudgeY: CGFloat = tiny ? 0.0 : moonR * 0.06
    let moonC = CGPoint(x: screenRect.midX + nudgeX, y: screenRect.midY - nudgeY)
    // A fatter crescent survives 16/32 px better.
    let biteR: CGFloat = moonR * (small ? 0.78 : 0.84)
    let biteDX: CGFloat = moonR * (tiny ? 0.66 : (small ? 0.56 : 0.46))
    let biteDY: CGFloat = moonR * (tiny ? 0.22 : (small ? 0.38 : 0.30))
    let biteC = CGPoint(x: moonC.x + biteDX, y: moonC.y - biteDY)
    let moonBox = CGRect(x: moonC.x - moonR, y: moonC.y - moonR, width: moonR * 2.0, height: moonR * 2.0)
    let biteBox = CGRect(x: biteC.x - biteR, y: biteC.y - biteR, width: biteR * 2.0, height: biteR * 2.0)

    // Ambient spill of the crescent's light on the panel.
    let spillAlpha: CGFloat = small ? 0.16 : 0.30
    let spill = gradient([rgba(0x39E6FF, spillAlpha), rgba(0x6A5BFF, 0.12), rgba(0x6A5BFF, 0.0)], [0.0, 0.5, 1.0])
    fillRadial(ctx, spill, center: moonC, radius: screenRect.width * 0.55)

    func drawCrescent(glowBlur: CGFloat, glowAlpha: CGFloat) {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: glowBlur * s, color: rgba(0x35E0FF, glowAlpha))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.saveGState()
        ctx.addEllipse(in: moonBox)
        ctx.clip()
        let moonEndColor: CGColor = small ? rgba(0x5FDCFF) : rgba(0x5C9BFF)
        let moonGradient = gradient([rgba(0xD8FFFF), rgba(0x5FF1FF), moonEndColor], [0.0, 0.45, 1.0])
        let moonStart = CGPoint(x: moonBox.minX, y: moonBox.minY)
        let moonEnd = CGPoint(x: moonBox.maxX, y: moonBox.maxY)
        fillLinear(ctx, moonGradient, from: moonStart, to: moonEnd)
        ctx.restoreGState()
        ctx.setBlendMode(.clear)
        ctx.addEllipse(in: biteBox)
        ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
    if !small {
        drawCrescent(glowBlur: 90, glowAlpha: 0.75)
    }
    drawCrescent(glowBlur: 28, glowAlpha: 0.85)

    // Funky accent: magenta sparkles in the crescent's hollow (large sizes only).
    func drawSparkle(center: CGPoint, radius: CGFloat, color: CGColor) {
        let tips: [CGPoint] = [
            CGPoint(x: center.x, y: center.y - radius),
            CGPoint(x: center.x + radius, y: center.y),
            CGPoint(x: center.x, y: center.y + radius),
            CGPoint(x: center.x - radius, y: center.y),
        ]
        let star = CGMutablePath()
        star.move(to: tips[3])
        for tip in tips {
            star.addQuadCurve(to: tip, control: center)
        }
        star.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 26.0 * s, color: rgba(0xFF3FD0, 0.95))
        ctx.addPath(star)
        ctx.setFillColor(color)
        ctx.fillPath()
        ctx.restoreGState()
    }
    if !small {
        let bigX: CGFloat = moonC.x + moonR * 1.22
        let bigY: CGFloat = moonC.y - moonR * 0.62
        drawSparkle(center: CGPoint(x: bigX, y: bigY), radius: moonR * 0.40, color: rgba(0xFF8CE6))
        let tinyX: CGFloat = moonC.x + moonR * 1.78
        let tinyY: CGFloat = moonC.y + moonR * 0.10
        drawSparkle(center: CGPoint(x: tinyX, y: tinyY), radius: moonR * 0.20, color: rgba(0xFF8CE6))
    }

    // Glass sheen across the top-left of the panel (large sizes only).
    if !small {
        let sheen = CGMutablePath()
        let sx0: CGFloat = screenRect.minX
        let sy0: CGFloat = screenRect.minY
        let sheenW: CGFloat = screenRect.width * 0.62
        let sheenCut: CGFloat = screenRect.width * 0.30
        sheen.move(to: CGPoint(x: sx0, y: sy0))
        sheen.addLine(to: CGPoint(x: sx0 + sheenW, y: sy0))
        sheen.addLine(to: CGPoint(x: sx0 + sheenCut, y: screenRect.maxY))
        sheen.addLine(to: CGPoint(x: sx0, y: screenRect.maxY))
        sheen.closeSubpath()
        ctx.saveGState()
        ctx.addPath(sheen)
        ctx.clip()
        let sheenGradient = gradient([rgba(0xFFFFFF, 0.10), rgba(0xFFFFFF, 0.0)], [0.0, 1.0])
        fillLinear(ctx, sheenGradient,
                   from: CGPoint(x: sx0, y: sy0), to: CGPoint(x: sx0 + sheenCut, y: screenRect.maxY))
        ctx.restoreGState()
    }

    ctx.restoreGState()   // screen clip
    ctx.restoreGState()   // body clip
    ctx.restoreGState()   // flip
}

// MARK: - Bitmap plumbing

func makeContext(_ pixels: Int) -> CGContext {
    let info: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                        bytesPerRow: 0, space: sRGB, bitmapInfo: info)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

func render(_ pixels: Int) -> CGImage {
    let ctx = makeContext(pixels)
    drawIcon(ctx, size: CGFloat(pixels))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL, dpi: Double = 72.0) {
    let type = "public.png" as CFString
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
        fatalError("cannot create \(url.path)")
    }
    let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    if !CGImageDestinationFinalize(dest) {
        fatalError("cannot write \(url.path)")
    }
}

/// Small renditions scaled up with nearest-neighbour, on a light and a dark strip.
func writePreview(_ images: [Int: CGImage], to url: URL) {
    let sizes: [Int] = [16, 32, 64, 128, 256]
    let cell: Int = 256
    let pad: Int = 24
    let width: Int = pad + sizes.count * (cell + pad)
    let height: Int = 2 * (cell + 2 * pad)
    let info: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: sRGB, bitmapInfo: info)!
    let rowH: Int = cell + 2 * pad
    ctx.setFillColor(rgba(0xE9E9EC))
    ctx.fill(CGRect(x: 0, y: rowH, width: width, height: rowH))
    ctx.setFillColor(rgba(0x26262B))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: rowH))
    ctx.interpolationQuality = .none
    for row in 0..<2 {
        for (i, px) in sizes.enumerated() {
            guard let image = images[px] else { continue }
            let x: Int = pad + i * (cell + pad)
            let y: Int = row * rowH + pad
            ctx.draw(image, in: CGRect(x: x, y: y, width: cell, height: cell))
        }
    }
    writePNG(ctx.makeImage()!, to: url)
}

// MARK: - Main

let fm = FileManager.default
let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let repoRoot: URL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let designDir: URL = repoRoot.appendingPathComponent("Design")
let resourcesDir: URL = repoRoot.appendingPathComponent("App/Resources")
let masterURL: URL = designDir.appendingPathComponent("AppIcon-1024.png")
let icnsURL: URL = resourcesDir.appendingPathComponent("AppIcon.icns")

var previewDir: URL? = nil
let arguments: [String] = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--preview"), flag + 1 < arguments.count {
    previewDir = URL(fileURLWithPath: arguments[flag + 1])
}

try fm.createDirectory(at: designDir, withIntermediateDirectories: true)
try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

let pixelSizes: [Int] = [16, 32, 64, 128, 256, 512, 1024]
var rendered: [Int: CGImage] = [:]
for px in pixelSizes {
    rendered[px] = render(px)
}

writePNG(rendered[1024]!, to: masterURL)
print("wrote \(masterURL.path)")

// The iconset is scratch: keep it out of the repo (anything under App/ gets bundled).
let workDir: URL = fm.temporaryDirectory.appendingPathComponent("shadowpcadvanced-icon-\(UUID().uuidString)")
let iconsetURL: URL = workDir.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let members: [(name: String, pixels: Int, dpi: Double)] = [
    ("icon_16x16.png", 16, 72), ("icon_16x16@2x.png", 32, 144),
    ("icon_32x32.png", 32, 72), ("icon_32x32@2x.png", 64, 144),
    ("icon_128x128.png", 128, 72), ("icon_128x128@2x.png", 256, 144),
    ("icon_256x256.png", 256, 72), ("icon_256x256@2x.png", 512, 144),
    ("icon_512x512.png", 512, 72), ("icon_512x512@2x.png", 1024, 144),
]
for member in members {
    let url: URL = iconsetURL.appendingPathComponent(member.name)
    writePNG(rendered[member.pixels]!, to: url, dpi: member.dpi)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try iconutil.run()
iconutil.waitUntilExit()
let iconutilStatus: Int32 = iconutil.terminationStatus
try? fm.removeItem(at: workDir)
if iconutilStatus != 0 {
    fatalError("iconutil failed with status \(iconutilStatus)")
}
print("wrote \(icnsURL.path)")

if let dir = previewDir {
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let sheetURL: URL = dir.appendingPathComponent("AppIcon-preview.png")
    writePreview(rendered, to: sheetURL)
    print("wrote \(sheetURL.path)")
}
