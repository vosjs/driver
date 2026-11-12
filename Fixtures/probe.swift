// Reads pixels out of a recording, for the tests: the mean colour of rectangles of one frame.
//
//   probe <recording.mp4> <seconds> <x,y,w,h> [<x,y,w,h> ...]
//
// Rectangles are in the recording's own pixels, origin top-left. A negative x or y counts
// from the right or the bottom edge. It prints one JSON object:
//   {"width": w, "height": h, "time": t, "colors": [[r, g, b], ...]}     (0 to 255)
import AVFoundation
import CoreGraphics
import Foundation

func fail(_ why: String) -> Never {
  FileHandle.standardError.write("probe: \(why)\n".data(using: .utf8)!)
  exit(1)
}

let args = CommandLine.arguments
guard args.count >= 4, let seconds = Double(args[2]) else {
  fail("usage: probe <recording.mp4> <seconds> <x,y,w,h> ...")
}

let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

let wanted = CMTime(seconds: seconds, preferredTimescale: 600)
let image: CGImage
let actual: CMTime
do {
  (image, actual) = try await generator.image(at: wanted)
} catch {
  fail("no frame at \(seconds) s: \(error.localizedDescription)")
}

let w = image.width
let h = image.height
var pixels = [UInt8](repeating: 0, count: w * h * 4)
guard
  let context = CGContext(
    data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fail("no bitmap to draw the frame into") }
context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

var colors: [[Int]] = []
for spec in args.dropFirst(3) {
  let n = spec.split(separator: ",").compactMap { Int($0) }
  guard n.count == 4, n[2] > 0, n[3] > 0 else { fail("a rectangle is x,y,w,h: \(spec)") }
  let x0 = n[0] < 0 ? w + n[0] : n[0]
  let y0 = n[1] < 0 ? h + n[1] : n[1]
  guard x0 >= 0, y0 >= 0, x0 + n[2] <= w, y0 + n[3] <= h else {
    fail("\(spec) is outside the \(w) x \(h) frame")
  }
  var sum = [0, 0, 0]
  for y in y0..<(y0 + n[3]) {
    for x in x0..<(x0 + n[2]) {
      let i = (y * w + x) * 4
      sum[0] += Int(pixels[i])
      sum[1] += Int(pixels[i + 1])
      sum[2] += Int(pixels[i + 2])
    }
  }
  let count = n[2] * n[3]
  colors.append(sum.map { $0 / count })
}

let out: [String: Any] = ["width": w, "height": h, "time": actual.seconds, "colors": colors]
let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
