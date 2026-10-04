#!/usr/bin/env swift
// Generates Docket's app icon (AppIcon.icns) and alarm sound (DocketAlarm.wav).
// Usage: swift scripts/make-assets.swift <output-dir>
import AppKit
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/assets", isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: - Icon

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // Squircle body on the macOS icon grid (824pt body, 100pt margin).
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    ctx.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    ctx.restoreGState()

    // Ink and paper: flat ink body, no gradient.
    let ink = NSColor(srgbRed: 0x0E / 255, green: 0x0E / 255, blue: 0x0C / 255, alpha: 1)
    let paper = NSColor(srgbRed: 0xFB / 255, green: 0xFB / 255, blue: 0xF9 / 255, alpha: 1)
    let ink3 = NSColor(srgbRed: 0xA3 / 255, green: 0xA3 / 255, blue: 0x9E / 255, alpha: 1)
    let fillStrong = NSColor(srgbRed: 0xE9 / 255, green: 0xE9 / 255, blue: 0xE5 / 255, alpha: 1)
    ink.setFill()
    shape.fill()

    // Paper card.
    let card = NSRect(x: 262, y: 222, width: 500, height: 590)
    let cardPath = NSBezierPath(roundedRect: card, xRadius: 64, yRadius: 64)
    ctx.saveGState()
    let cardShadow = NSShadow()
    cardShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    cardShadow.shadowBlurRadius = 30
    cardShadow.shadowOffset = NSSize(width: 0, height: -14)
    cardShadow.set()
    paper.setFill()
    cardPath.fill()
    ctx.restoreGState()

    // Checklist rows.
    let accent = ink
    for (i, y) in [664.0, 520.0, 376.0].enumerated() {
        let circle = NSRect(x: 318, y: y - 36, width: 72, height: 72)
        let c = NSBezierPath(ovalIn: circle)
        if i == 0 {
            accent.setFill()
            c.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: circle.minX + 18, y: circle.midY + 1))
            check.line(to: NSPoint(x: circle.minX + 31, y: circle.midY - 13))
            check.line(to: NSPoint(x: circle.maxX - 16, y: circle.midY + 15))
            check.lineWidth = 10
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            paper.setStroke()
            check.stroke()
        } else {
            c.lineWidth = 9
            ink3.setStroke()
            let inset = NSBezierPath(ovalIn: circle.insetBy(dx: 4.5, dy: 4.5))
            inset.lineWidth = 9
            inset.stroke()
        }
        let lineWidth: CGFloat = i == 0 ? 230 : (i == 1 ? 270 : 190)
        let line = NSBezierPath(roundedRect: NSRect(x: 420, y: y - 13, width: lineWidth, height: 26), xRadius: 13, yRadius: 13)
        (i == 0 ? fillStrong : ink.withAlphaComponent(0.78)).setFill()
        line.fill()
    }

    // Alarm badge.
    let badge = NSRect(x: 618, y: 168, width: 236, height: 236)
    ctx.saveGState()
    let badgeShadow = NSShadow()
    badgeShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    badgeShadow.shadowBlurRadius = 18
    badgeShadow.shadowOffset = NSSize(width: 0, height: -8)
    badgeShadow.set()
    ink.setFill()
    NSBezierPath(ovalIn: badge).fill()
    ctx.restoreGState()
    paper.setStroke()
    let ring = NSBezierPath(ovalIn: badge.insetBy(dx: 6, dy: 6))
    ring.lineWidth = 12
    ring.stroke()
    // Let the symbol renderer colour the glyph; compositing tricks bleed into the badge at some scales.
    let white = NSImage.SymbolConfiguration(pointSize: 118, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [paper]))
    if let symbol = NSImage(systemSymbolName: "alarm.fill", accessibilityDescription: nil)?.withSymbolConfiguration(white) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: badge.midX - s.width / 2, y: badge.midY - s.height / 2 - 4, width: s.width, height: s.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
// Draw once at full size and scale down: SF Symbols render unreliably in scaled bitmap contexts.
let master = drawIcon(size: 1024)
func scaled(_ px: Int) -> NSBitmapImageRep {
    guard px != 1024 else { return master }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    master.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try scaled(base * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try master.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()

// MARK: - Alarm sound (classic 4-beep digital alarm, loops seamlessly)

let sampleRate = 44_100.0
var samples: [Int16] = []
func tone(_ duration: Double, freq: Double, amp: Double) {
    let n = Int(duration * sampleRate)
    for i in 0..<n {
        let t = Double(i) / sampleRate
        let env = min(1, t / 0.004) * min(1, (duration - t) / 0.012)
        let v = sin(2 * .pi * freq * t) + 0.35 * sin(2 * .pi * freq * 2 * t) + 0.15 * sin(2 * .pi * freq * 3 * t)
        samples.append(Int16(max(-1, min(1, v / 1.5 * amp * env)) * Double(Int16.max)))
    }
}
func silence(_ duration: Double) { samples += Array(repeating: 0, count: Int(duration * sampleRate)) }

for _ in 0..<4 {
    tone(0.085, freq: 2093, amp: 0.85) // C7
    silence(0.055)
}
silence(0.45)

var wav = Data()
func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
let dataBytes = samples.count * 2
wav.append("RIFF".data(using: .ascii)!); append(UInt32(36 + dataBytes))
wav.append("WAVE".data(using: .ascii)!)
wav.append("fmt ".data(using: .ascii)!); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
wav.append("data".data(using: .ascii)!); append(UInt32(dataBytes))
for s in samples { append(s) }
try wav.write(to: outDir.appendingPathComponent("DocketAlarm.wav"))

print("Assets written to \(outDir.path)")
