#!/usr/bin/env swift
//
// make-icon.swift
//
// Standalone CoreGraphics art generator for the RepoDeck app icon.
// Draws "fanned status cards" on a green -> emerald squircle tile and
// writes a single 1024x1024 transparent PNG.
//
// Usage: swift Scripts/make-icon.swift <output.png>
//
// No dependencies beyond AppKit/CoreGraphics (both ship with the OS), so
// this is reproducible on any Mac with a Swift toolchain.

import AppKit
import CoreGraphics

// MARK: - Argument parsing

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift Scripts/make-icon.swift <output.png>\n".data(using: .utf8)!)
    exit(1)
}
let outputPath = arguments[1]

// MARK: - Color helpers

let colorSpace = CGColorSpaceCreateDeviceRGB()

/// Builds a CGColor in the context's own color space from a 0xRRGGBB literal.
func rgba(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255.0
    let g = CGFloat((hex >> 8) & 0xFF) / 255.0
    let b = CGFloat(hex & 0xFF) / 255.0
    return CGColor(colorSpace: colorSpace, components: [r, g, b, alpha])!
}

// MARK: - Canvas setup

let canvasSize: CGFloat = 1024

guard let ctx = CGContext(
    data: nil,
    width: Int(canvasSize),
    height: Int(canvasSize),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("error: could not create CGContext\n".data(using: .utf8)!)
    exit(1)
}

// Transparent background: a freshly-allocated CGContext (data: nil) is
// zero-filled, which is already fully transparent. Nothing to draw.

// MARK: - Tile (rounded "app tile", ~90% of canvas, centered)

let margin = canvasSize * 0.05
let tileRect = CGRect(x: margin, y: margin, width: canvasSize - 2 * margin, height: canvasSize - 2 * margin)
let tileCornerRadius = tileRect.width * 0.2237
let tilePath = CGPath(roundedRect: tileRect, cornerWidth: tileCornerRadius, cornerHeight: tileCornerRadius, transform: nil)

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

// Diagonal top-left -> bottom-right emerald gradient.
// (CGContext bitmap space is y-up: "top" = maxY, "bottom" = minY.)
let tileGradientColors = [rgba(0x34D399), rgba(0x059669)] as CFArray
if let tileGradient = CGGradient(colorsSpace: colorSpace, colors: tileGradientColors, locations: [0, 1]) {
    let topLeft = CGPoint(x: tileRect.minX, y: tileRect.maxY)
    let bottomRight = CGPoint(x: tileRect.maxX, y: tileRect.minY)
    ctx.drawLinearGradient(tileGradient, start: topLeft, end: bottomRight, options: [])
}

// Subtle inner top highlight for a touch of depth.
let highlightRect = CGRect(x: tileRect.minX, y: tileRect.midY, width: tileRect.width, height: tileRect.height * 0.5)
let highlightColors = [rgba(0xFFFFFF, alpha: 0.16), rgba(0xFFFFFF, alpha: 0.0)] as CFArray
if let highlightGradient = CGGradient(colorsSpace: colorSpace, colors: highlightColors, locations: [0, 1]) {
    let top = CGPoint(x: tileRect.midX, y: highlightRect.maxY)
    let bottom = CGPoint(x: tileRect.midX, y: highlightRect.minY)
    ctx.drawLinearGradient(highlightGradient, start: top, end: bottom, options: [])
}

ctx.restoreGState()

// MARK: - Fanned status cards

let cardWidth = tileRect.width * 0.46
let cardHeight = cardWidth * 1.35
let cardCornerRadius = cardWidth * 0.12

// Shared lower pivot the cards fan out from, like a held hand of cards.
let pivot = CGPoint(x: tileRect.midX, y: tileRect.minY + tileRect.height * 0.32)

// Card rect in local (pre-rotation) space: bottom edge sits just below the
// pivot, body extends upward, so rotating about the origin fans the cards.
let cardLocalRect = CGRect(
    x: -cardWidth / 2,
    y: -cardHeight * 0.12,
    width: cardWidth,
    height: cardHeight
)
let cardPath = CGPath(roundedRect: cardLocalRect, cornerWidth: cardCornerRadius, cornerHeight: cardCornerRadius, transform: nil)

let cardFillColor = rgba(0xFFFFFF, alpha: 0.98)
let shadowColor = rgba(0x000000, alpha: 0.28)

// Draw back-to-front: left, right, then the upright center card on top.
let cardAngles: [CGFloat] = [-10, 10, 0]

for degrees in cardAngles {
    ctx.saveGState()
    ctx.translateBy(x: pivot.x, y: pivot.y)
    ctx.rotate(by: degrees * .pi / 180)
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: shadowColor)
    ctx.addPath(cardPath)
    ctx.setFillColor(cardFillColor)
    ctx.fillPath()
    ctx.restoreGState()
}

// MARK: - Status dot on the top (upright, center) card

// The center card has rotation 0, so its local frame maps to the canvas
// via a pure translation by `pivot` — no rotation math needed.
let dotRadius = cardWidth * 0.065
let dotCenter = CGPoint(
    x: pivot.x + cardLocalRect.minX + cardWidth * 0.20,
    y: pivot.y + cardLocalRect.maxY - cardHeight * 0.16
)
let dotRect = CGRect(
    x: dotCenter.x - dotRadius,
    y: dotCenter.y - dotRadius,
    width: dotRadius * 2,
    height: dotRadius * 2
)

ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.setFillColor(rgba(0x7A5CFF))
ctx.addEllipse(in: dotRect)
ctx.fillPath()
ctx.restoreGState()

// MARK: - Write PNG

guard let cgImage = ctx.makeImage() else {
    FileHandle.standardError.write("error: could not render CGImage\n".data(using: .utf8)!)
    exit(1)
}

let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("error: could not encode PNG\n".data(using: .utf8)!)
    exit(1)
}

do {
    try pngData.write(to: URL(fileURLWithPath: outputPath))
    print("Wrote \(outputPath)")
} catch {
    FileHandle.standardError.write("error: could not write \(outputPath): \(error)\n".data(using: .utf8)!)
    exit(1)
}
