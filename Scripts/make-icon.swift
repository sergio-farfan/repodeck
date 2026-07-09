#!/usr/bin/env swift
//
// make-icon.swift
//
// Standalone CoreGraphics art generator for RepoDeck's icon art.
//
// Draws a purple commit graph (main line + one diverge/merge branch) on a
// black squircle tile, and writes a single 1024x1024 transparent PNG.
//
// A second mode renders the DMG installer background: a full-bleed black
// gradient with a subtle "drag me over there" arrow between where the app
// icon and Applications-folder shortcut will sit.
//
// Usage:
//   swift Scripts/make-icon.swift <output.png>                  (app icon, 1024x1024)
//   swift Scripts/make-icon.swift --dmg-background <output.png> (DMG background, 1200x800 @2x)
//
// No dependencies beyond AppKit/CoreGraphics (both ship with the OS), so
// this is reproducible on any Mac with a Swift toolchain.

import AppKit
import CoreGraphics

// MARK: - Argument parsing

enum Mode {
    case appIcon(path: String)
    case dmgBackground(path: String)
}

func usageAndExit() -> Never {
    FileHandle.standardError.write("""
    usage: swift Scripts/make-icon.swift <output.png>
           swift Scripts/make-icon.swift --dmg-background <output.png>\n
    """.data(using: .utf8)!)
    exit(1)
}

let arguments = CommandLine.arguments
let mode: Mode
switch arguments.count {
case 2:
    mode = .appIcon(path: arguments[1])
case 3 where arguments[1] == "--dmg-background":
    mode = .dmgBackground(path: arguments[2])
default:
    usageAndExit()
}

// MARK: - Color helpers

let colorSpace = CGColorSpaceCreateDeviceRGB()

/// Builds a CGColor in the context's own color space from a 0xRRGGBB literal.
func rgba(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255.0
    let g = CGFloat((hex >> 8) & 0xFF) / 255.0
    let b = CGFloat(hex & 0xFF) / 255.0
    return CGColor(colorSpace: colorSpace, components: [r, g, b, alpha])!
}

let purpleStroke: UInt32 = 0xA100FF
let purpleCore: UInt32 = 0xD4A0FF
let tileGradientTop: UInt32 = 0x1C1C1E
let tileGradientBottom: UInt32 = 0x000000

// MARK: - Canvas helpers

func makeContext(width: Int, height: Int) -> CGContext {
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        FileHandle.standardError.write("error: could not create CGContext\n".data(using: .utf8)!)
        exit(1)
    }
    // A freshly-allocated CGContext (data: nil) is zero-filled, i.e. fully
    // transparent. Nothing to draw for a transparent background.
    return ctx
}

func writePNG(_ ctx: CGContext, to outputPath: String) {
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
}

/// Draws a vertical gradient (top color -> bottom color) over `rect` in the
/// current clip. Caller is responsible for clipping/saving/restoring state.
func drawVerticalGradient(_ ctx: CGContext, rect: CGRect, top: UInt32, bottom: UInt32) {
    let colors = [rgba(top), rgba(bottom)] as CFArray
    guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { return }
    let topPoint = CGPoint(x: rect.midX, y: rect.maxY)
    let bottomPoint = CGPoint(x: rect.midX, y: rect.minY)
    ctx.drawLinearGradient(gradient, start: topPoint, end: bottomPoint, options: [])
}

// MARK: - Commit-graph motif

/// A main line (top -> branch-point -> merge-point -> bottom) with a single
/// branch that diverges right after the branch-point, runs parallel for a
/// stretch (carrying one node), and curves back to merge at the merge-point.
///
/// `rect` is the area the graph is laid out within (the app tile, or a small
/// corner box for the faint DMG-background motif). `alpha` scales both the
/// stroke and node colors, so callers can render a low-opacity variant.
func drawCommitGraph(_ ctx: CGContext, in rect: CGRect, lineWidth: CGFloat, nodeRadius: CGFloat, coreRadius: CGFloat, alpha: CGFloat = 1) {
    let mainX = rect.minX + rect.width * 0.42
    let branchX = rect.minX + rect.width * 0.63

    let spanHeight = rect.height * 0.62
    let topY = rect.midY + spanHeight / 2
    let bottomY = rect.midY - spanHeight / 2

    // Four evenly spaced nodes along the main line.
    let topNodeY = topY
    let branchPointY = topY - spanHeight * (1.0 / 3.0)
    let mergePointY = topY - spanHeight * (2.0 / 3.0)
    let bottomNodeY = bottomY

    // The diverge/merge curves end in a short vertical run so the branch
    // line is parallel to the main line for a stretch (where its node sits).
    let gap = branchPointY - mergePointY
    let curveReach = gap * 0.35
    let curveEndTop = branchPointY - curveReach
    let curveEndBottom = mergePointY + curveReach
    let branchNodeY = (branchPointY + mergePointY) / 2

    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(lineWidth)
    ctx.setStrokeColor(rgba(purpleStroke, alpha: alpha))

    // Main vertical line: continuous from top to bottom.
    let mainLine = CGMutablePath()
    mainLine.move(to: CGPoint(x: mainX, y: topNodeY))
    mainLine.addLine(to: CGPoint(x: mainX, y: bottomNodeY))
    ctx.addPath(mainLine)
    ctx.strokePath()

    // Branch: diverge from branch-point, run parallel past its own node,
    // merge back in at merge-point. Control points are chosen so the curve
    // has a vertical tangent at both ends of each cubic segment, giving a
    // smooth S-curve with no sharp corners at the diverge/merge/parallel
    // transitions.
    let branch = CGMutablePath()
    branch.move(to: CGPoint(x: mainX, y: branchPointY))
    let divergeMidY = (branchPointY + curveEndTop) / 2
    branch.addCurve(
        to: CGPoint(x: branchX, y: curveEndTop),
        control1: CGPoint(x: mainX, y: divergeMidY),
        control2: CGPoint(x: branchX, y: divergeMidY)
    )
    branch.addLine(to: CGPoint(x: branchX, y: curveEndBottom))
    let mergeMidY = (curveEndBottom + mergePointY) / 2
    branch.addCurve(
        to: CGPoint(x: mainX, y: mergePointY),
        control1: CGPoint(x: branchX, y: mergeMidY),
        control2: CGPoint(x: mainX, y: mergeMidY)
    )
    ctx.addPath(branch)
    ctx.strokePath()
    ctx.restoreGState()

    // Nodes on top of the lines: filled outer circle + bright inner core.
    let nodeCenters = [
        CGPoint(x: mainX, y: topNodeY),
        CGPoint(x: mainX, y: branchPointY),
        CGPoint(x: branchX, y: branchNodeY),
        CGPoint(x: mainX, y: mergePointY),
        CGPoint(x: mainX, y: bottomNodeY),
    ]

    ctx.saveGState()
    for center in nodeCenters {
        let outerRect = CGRect(x: center.x - nodeRadius, y: center.y - nodeRadius, width: nodeRadius * 2, height: nodeRadius * 2)
        ctx.setFillColor(rgba(purpleStroke, alpha: alpha))
        ctx.addEllipse(in: outerRect)
        ctx.fillPath()

        let coreRect = CGRect(x: center.x - coreRadius, y: center.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2)
        ctx.setFillColor(rgba(purpleCore, alpha: alpha))
        ctx.addEllipse(in: coreRect)
        ctx.fillPath()
    }
    ctx.restoreGState()
}

// MARK: - App icon (1024x1024, transparent margin, rounded tile)

func renderAppIcon(to outputPath: String) {
    let canvasSize: CGFloat = 1024
    let ctx = makeContext(width: Int(canvasSize), height: Int(canvasSize))

    let margin = canvasSize * 0.05
    let tileRect = CGRect(x: margin, y: margin, width: canvasSize - 2 * margin, height: canvasSize - 2 * margin)
    let tileCornerRadius = tileRect.width * 0.2237
    let tilePath = CGPath(roundedRect: tileRect, cornerWidth: tileCornerRadius, cornerHeight: tileCornerRadius, transform: nil)

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    drawVerticalGradient(ctx, rect: tileRect, top: tileGradientTop, bottom: tileGradientBottom)
    ctx.restoreGState()

    drawCommitGraph(ctx, in: tileRect, lineWidth: 30, nodeRadius: 44, coreRadius: 20)

    writePNG(ctx, to: outputPath)
}

// MARK: - DMG background (1200x800 @2x, full bleed, no rounded corners)

func renderDMGBackground(to outputPath: String) {
    let width = 1200
    let height = 800
    let ctx = makeContext(width: width, height: height)
    let canvasRect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))

    drawVerticalGradient(ctx, rect: canvasRect, top: tileGradientTop, bottom: tileGradientBottom)

    // Faint commit-graph motif tucked in the bottom-left corner, low opacity
    // so it stays a texture rather than competing with the Finder icons.
    let motifRect = CGRect(x: -40, y: -60, width: 360, height: 420)
    drawCommitGraph(ctx, in: motifRect, lineWidth: 16, nodeRadius: 22, coreRadius: 10, alpha: 0.14)

    // Horizontal "drag it over there" arrow, centered vertically, sitting
    // between the app-icon slot (~x=300) and the Applications-folder slot
    // (~x=900) — both left clear for Finder to draw the real icons.
    let arrowY = CGFloat(height) / 2
    let shaftStartX: CGFloat = 430
    let shaftEndX: CGFloat = 770
    let headBackX: CGFloat = 725
    let headHalfHeight: CGFloat = 26

    let arrowPath = CGMutablePath()
    arrowPath.move(to: CGPoint(x: shaftStartX, y: arrowY))
    arrowPath.addLine(to: CGPoint(x: shaftEndX, y: arrowY))
    arrowPath.move(to: CGPoint(x: headBackX, y: arrowY - headHalfHeight))
    arrowPath.addLine(to: CGPoint(x: shaftEndX, y: arrowY))
    arrowPath.addLine(to: CGPoint(x: headBackX, y: arrowY + headHalfHeight))

    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(14)
    ctx.setStrokeColor(rgba(purpleStroke, alpha: 0.6))
    ctx.addPath(arrowPath)
    ctx.strokePath()
    ctx.restoreGState()

    writePNG(ctx, to: outputPath)
}

// MARK: - Dispatch

switch mode {
case .appIcon(let path):
    renderAppIcon(to: path)
case .dmgBackground(let path):
    renderDMGBackground(to: path)
}
