// Build an .icns for Snoopy Wallpaper from a source image.
//
//   swift Tools/MakeAppIcon.swift <source image> <output.icns> [centerX centerY side]
//
// The optional numbers pick the square crop (source pixels). Without them the
// crop is framed for Resources/ScreenSaverPreview.png: Snoopy's head on the
// right, Woodstock on the left. The crop is drawn into the standard macOS icon
// grid (a rounded square filling 824 of 1024 points, 22.5 % corner radius) at
// every size iconutil needs.
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: MakeAppIcon.swift <source> <output.icns> [centerX centerY side]\n".utf8))
    exit(2)
}
let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read \(sourceURL.path)\n".utf8))
    exit(1)
}

let width = CGFloat(image.width)
let height = CGFloat(image.height)
var centerX = width * 0.46
var centerY = height * 0.5
var side = min(width, height) * 0.995
if arguments.count >= 6, let x = Double(arguments[3]), let y = Double(arguments[4]), let s = Double(arguments[5]) {
    centerX = CGFloat(x)
    centerY = CGFloat(y)
    side = CGFloat(s)
}
side = min(side, width, height)
let crop = CGRect(
    x: max(0, min(width - side, centerX - side / 2)),
    y: max(0, min(height - side, centerY - side / 2)),
    width: side, height: side
)
guard let cropped = image.cropping(to: crop) else {
    FileHandle.standardError.write(Data("cannot crop \(crop)\n".utf8))
    exit(1)
}

func render(pixels: Int) -> CGImage? {
    let canvas = CGFloat(pixels)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return nil }
    context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    let inset = canvas * 100 / 1024
    let rect = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let radius = rect.width * 0.225
    context.saveGState()
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    context.interpolationQuality = .high
    context.draw(cropped, in: rect)
    context.restoreGState()
    return context.makeImage()
}

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("SnoopyAppIcon-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        guard let rendered = render(pixels: base * scale) else { continue }
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let url = iconset.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { continue }
        CGImageDestinationAddImage(destination, rendered, nil)
        CGImageDestinationFinalize(destination)
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus == 0 ? 0 : 1)
