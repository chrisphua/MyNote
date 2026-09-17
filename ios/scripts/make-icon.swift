#!/usr/bin/env swift
//
// Generates the iOS app icon.
//
// Kept as code rather than a committed binary so the icon can be regenerated
// when the brand changes, and so a reviewer can see exactly what it draws. Run:
//
//     swift scripts/make-icon.swift MyNote/Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png
//
// Matches the Android adaptive icon in android/app/src/main/res: a white page
// with accent-coloured lines on the MyNote blue.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Icon-1024.png"

// No alpha channel: the App Store rejects icons with transparency, and iOS
// applies its own corner mask.
guard let context = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("could not create bitmap context")
}

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

let accent = color(0x2F6FED)      // ThemeSpec.defaultTheme.light.accent
let accentDeep = color(0x1E4FD0)
let paper = color(0xFFFFFF)
let fold = color(0xC7D7FF)

// Background: a slight gradient so the icon does not read as flat at size.
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [accent, accentDeep] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: size, y: 0),
    options: []
)

// The page. Generous margins so it survives the system's rounded mask and
// still reads at 40pt on a home screen.
let pageWidth = size * 0.50
let pageHeight = size * 0.62
let pageX = (size - pageWidth) / 2
let pageY = (size - pageHeight) / 2
let corner = size * 0.045
let foldSize = size * 0.13

// Page outline with a folded top-right corner, drawn as one path.
let page = CGMutablePath()
page.move(to: CGPoint(x: pageX + corner, y: pageY))
page.addLine(to: CGPoint(x: pageX + pageWidth - corner, y: pageY))
page.addQuadCurve(to: CGPoint(x: pageX + pageWidth, y: pageY + corner),
                  control: CGPoint(x: pageX + pageWidth, y: pageY))
page.addLine(to: CGPoint(x: pageX + pageWidth, y: pageY + pageHeight - foldSize))
page.addLine(to: CGPoint(x: pageX + pageWidth - foldSize, y: pageY + pageHeight))
page.addLine(to: CGPoint(x: pageX + corner, y: pageY + pageHeight))
page.addQuadCurve(to: CGPoint(x: pageX, y: pageY + pageHeight - corner),
                  control: CGPoint(x: pageX, y: pageY + pageHeight))
page.addLine(to: CGPoint(x: pageX, y: pageY + corner))
page.addQuadCurve(to: CGPoint(x: pageX + corner, y: pageY),
                  control: CGPoint(x: pageX, y: pageY))
page.closeSubpath()

context.setFillColor(paper)
context.addPath(page)
context.fillPath()

// The fold itself, a shade darker so the corner reads as turned.
let foldPath = CGMutablePath()
foldPath.move(to: CGPoint(x: pageX + pageWidth, y: pageY + pageHeight - foldSize))
foldPath.addLine(to: CGPoint(x: pageX + pageWidth - foldSize, y: pageY + pageHeight))
foldPath.addLine(to: CGPoint(x: pageX + pageWidth - foldSize, y: pageY + pageHeight - foldSize))
foldPath.closeSubpath()
context.setFillColor(fold)
context.addPath(foldPath)
context.fillPath()

// Three lines of text, shortening downwards. Three is enough to read as a note
// and few enough to stay legible when the icon is 40pt wide.
context.setFillColor(accent)
let lineHeight = size * 0.035
let lineGap = size * 0.075
let lineX = pageX + pageWidth * 0.16
let widths = [0.68, 0.68, 0.40]
for (index, fraction) in widths.enumerated() {
    let y = pageY + pageHeight * 0.58 - Double(index) * lineGap
    let rect = CGRect(x: lineX, y: y, width: pageWidth * fraction, height: lineHeight)
    context.addPath(CGPath(roundedRect: rect,
                           cornerWidth: lineHeight / 2,
                           cornerHeight: lineHeight / 2,
                           transform: nil))
    context.fillPath()
}

guard let image = context.makeImage() else { fatalError("could not render image") }

let url = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
)
guard let destination = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil
) else {
    fatalError("could not create \(outputPath)")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write PNG") }

print("wrote \(outputPath)")
