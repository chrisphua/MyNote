#!/usr/bin/env swift
//
// Generates the MyNote app icons.
//
// Shares a visual system with MyPlaylist so the two read as one family: a
// full-bleed diagonal gradient, a single bold white glyph, and a coloured glow.
// The hue is MyNote's own blue rather than MyPlaylist's purple, so the two are
// still tellable apart on a home screen.
//
// The glyph is drawn here rather than taken from SF Symbols. Apple's SF Symbols
// licence does not permit their use in app icons, and an original mark is also
// free to diverge later.
//
// Run:
//     swift scripts/make-icon.swift MyNote/Resources/Assets.xcassets/AppIcon.appiconset
//
// Writes AppIcon.png, AppIcon-Dark.png and AppIcon-Tinted.png — the light, dark
// and tinted appearances iOS 18 asks for.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// One appearance. iOS composites the tinted variant itself, so that one is
/// greyscale and leans on shape alone.
struct Appearance {
    let fileName: String
    let backgroundTop: UInt32
    let backgroundBottom: UInt32
    let glow: UInt32
    let glowAlpha: CGFloat
    /// Slight tint at the bottom of the glyph, as MyPlaylist's has.
    let glyphTint: UInt32
}

let appearances = [
    Appearance(fileName: "AppIcon.png",
               backgroundTop: 0x171E4F, backgroundBottom: 0x3A4FD0,
               glow: 0x5B8CFF, glowAlpha: 0.75, glyphTint: 0xD6E2FF),
    Appearance(fileName: "AppIcon-Dark.png",
               backgroundTop: 0x080B22, backgroundBottom: 0x1E2A7A,
               glow: 0x4E7CFF, glowAlpha: 0.85, glyphTint: 0xC3D4FF),
    Appearance(fileName: "AppIcon-Tinted.png",
               backgroundTop: 0x8E8E8E, backgroundBottom: 0x565656,
               glow: 0xFFFFFF, glowAlpha: 0.45, glyphTint: 0xEDEDED),
]

/// A page with a folded corner and three ruled lines.
///
/// The lines are subpaths filled with the even-odd rule, so they are holes that
/// show the background through rather than strokes painted on top. That keeps
/// the mark reading as written-on paper at 40pt, where drawn lines turn to mush.
func pageOutline() -> CGPath {
    let width = size * 0.40
    let height = size * 0.50
    let x = (size - width) / 2
    // Optically centred: a little high reads as centred once iOS rounds the corners.
    let y = (size - height) / 2 - size * 0.012
    let corner = size * 0.045
    let fold = size * 0.13

    let path = CGMutablePath()
    path.move(to: CGPoint(x: x + corner, y: y))
    path.addLine(to: CGPoint(x: x + width - corner, y: y))
    path.addQuadCurve(to: CGPoint(x: x + width, y: y + corner),
                      control: CGPoint(x: x + width, y: y))
    path.addLine(to: CGPoint(x: x + width, y: y + height - fold))
    path.addLine(to: CGPoint(x: x + width - fold, y: y + height))
    path.addLine(to: CGPoint(x: x + corner, y: y + height))
    path.addQuadCurve(to: CGPoint(x: x, y: y + height - corner),
                      control: CGPoint(x: x, y: y + height))
    path.addLine(to: CGPoint(x: x, y: y + corner))
    path.addQuadCurve(to: CGPoint(x: x + corner, y: y),
                      control: CGPoint(x: x, y: y))
    path.closeSubpath()
    return path
}

func pageWithRules() -> CGPath {
    let width = size * 0.40
    let height = size * 0.50
    let x = (size - width) / 2
    let y = (size - height) / 2 - size * 0.012

    let path = CGMutablePath()
    path.addPath(pageOutline())

    let lineHeight = size * 0.030
    let gap = size * 0.058
    let inset = width * 0.17
    // Three lines, the last one short — enough to read as text, few enough to
    // stay legible when the icon is 40pt wide.
    for (index, fraction) in [0.66, 0.66, 0.40].enumerated() {
        let lineY = y + height * 0.60 - Double(index) * gap
        let rect = CGRect(x: x + inset, y: lineY,
                          width: (width - inset * 2) * fraction / 0.66,
                          height: lineHeight)
        path.addPath(CGPath(roundedRect: rect,
                            cornerWidth: lineHeight / 2,
                            cornerHeight: lineHeight / 2,
                            transform: nil))
    }
    return path
}

func render(_ appearance: Appearance) throws {
    // No alpha: the App Store rejects an icon with transparency.
    guard let context = CGContext(
        data: nil, width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { throw Failure.context }

    let rgb = CGColorSpaceCreateDeviceRGB()

    // Background, top-left to bottom-right.
    let background = CGGradient(
        colorsSpace: rgb,
        colors: [color(appearance.backgroundTop), color(appearance.backgroundBottom)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(background,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: size, y: 0),
                               options: [])

    // A soft lift behind the glyph, so the centre does not read as flat.
    let halo = CGGradient(
        colorsSpace: rgb,
        colors: [color(0xFFFFFF, alpha: 0.16), color(0xFFFFFF, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(halo,
                               startCenter: CGPoint(x: size / 2, y: size / 2), startRadius: 0,
                               endCenter: CGPoint(x: size / 2, y: size / 2), endRadius: size * 0.34,
                               options: [])

    // Glow: the solid outline is filled once with a shadow set, which paints the
    // halo. Using the ruled path here would leak glow through the line holes.
    context.saveGState()
    context.setShadow(offset: .zero, blur: size * 0.055,
                      color: color(appearance.glow, alpha: appearance.glowAlpha))
    context.setFillColor(color(0xFFFFFF))
    context.addPath(pageOutline())
    context.fillPath()
    context.restoreGState()

    // The glyph itself: white falling to a faint tint, with the rules knocked out.
    context.saveGState()
    context.addPath(pageWithRules())
    context.clip(using: .evenOdd)
    let glyph = CGGradient(
        colorsSpace: rgb,
        colors: [color(0xFFFFFF), color(appearance.glyphTint)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(glyph,
                               start: CGPoint(x: 0, y: size * 0.78),
                               end: CGPoint(x: 0, y: size * 0.22),
                               options: [])
    context.restoreGState()

    guard let image = context.makeImage() else { throw Failure.render }

    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent(appearance.fileName)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { throw Failure.write(appearance.fileName) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure.write(appearance.fileName) }

    print("wrote \(appearance.fileName)")
}

enum Failure: Error {
    case context, render, write(String)
}

for appearance in appearances {
    try render(appearance)
}
