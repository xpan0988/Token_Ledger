import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func color(_ red: Double, _ green: Double, _ blue: Double) -> CGColor {
    CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

func renderIcon(size: Int) throws -> Data {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CocoaError(.fileWriteUnknown) }

    let scale = CGFloat(size) / 128
    context.scaleBy(x: scale, y: scale)
    let frame = CGRect(x: 9, y: 9, width: 110, height: 110)
    let tile = CGPath(roundedRect: frame, cornerWidth: 24, cornerHeight: 24, transform: nil)
    context.addPath(tile)
    context.setFillColor(color(25, 25, 27))
    context.fillPath()
    context.addPath(tile)
    context.setStrokeColor(color(73, 74, 76))
    context.setLineWidth(1)
    context.strokePath()
    context.setLineCap(.round)

    let center = CGPoint(x: 64, y: 72)
    for (radius, width, fraction, accent) in [
        (27.0, 5.0, 0.73, color(163, 191, 173)),
        (18.0, 4.0, 0.58, color(215, 160, 135)),
    ] {
        context.setLineWidth(width)
        context.setStrokeColor(accent.copy(alpha: 0.25)!)
        context.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        context.strokePath()
        context.setStrokeColor(accent)
        context.addArc(
            center: center,
            radius: radius,
            startAngle: .pi / 2,
            endAngle: .pi / 2 - 2 * .pi * fraction,
            clockwise: true)
        context.strokePath()
    }

    for (start, end, accent) in [(35.0, 68.0, color(163, 191, 173)), (75.0, 93.0, color(215, 160, 135))] {
        context.setLineWidth(4)
        context.setStrokeColor(accent)
        context.move(to: CGPoint(x: start, y: 31))
        context.addLine(to: CGPoint(x: end, y: 31))
        context.strokePath()
    }

    let data = NSMutableData()
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
}

func encodedLength(_ count: Int) -> Data {
    var value = UInt32(count).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

var icons = Data()
for (type, size) in [("icp4", 16), ("icp5", 32), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)] {
    let icon = try renderIcon(size: size)
    icons.append(Data(type.utf8))
    icons.append(encodedLength(icon.count + 8))
    icons.append(icon)
}

var container = Data("icns".utf8)
container.append(encodedLength(icons.count + 8))
container.append(icons)
try container.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
