// Makes an .icns from a pixel art PNG: every size of the iconset is scaled with nearest neighbor
// (sips would blur it).
//
// Usage: swift make_icon.swift <input.png> <output.icns>

import AppKit

let args = CommandLine.arguments
guard args.count == 3,
      let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write("usage: make_icon.swift <input.png> <output.icns>\n".data(using: .utf8)!)
    exit(1)
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent(UUID().uuidString)
    .appendingPathComponent("icon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func write(_ size: Int, _ name: String) throws {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}

for s in [16, 32, 128, 256, 512] {
    try write(s, "icon_\(s)x\(s).png")
    try write(s * 2, "icon_\(s)x\(s)@2x.png")
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", args[2]]
try p.run()
p.waitUntilExit()
exit(p.terminationStatus)
