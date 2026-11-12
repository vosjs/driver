// A window for the tests to record: titled, 480 x 320 of content in one flat colour, with a
// bar that moves so the capture has frames. It takes no focus and shows no Dock icon.
//
//   window [--color r,g,b] [--title text]
//
// It prints {"window": <id>} once it is on screen. On stdin, `move <dx> <dy>` moves it by
// that many points (right and down) and prints {"moved": true}. It exits when stdin closes.
import AppKit

var color: [CGFloat] = [40, 90, 160]
var title = "vos-driver fixture"
var args = Array(CommandLine.arguments.dropFirst())
while args.count >= 2 {
  let flag = args.removeFirst()
  let value = args.removeFirst()
  if flag == "--color" {
    let parts = value.split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
    if parts.count == 3 { color = parts }
  } else if flag == "--title" {
    title = value
  }
}
let fill = NSColor(srgbRed: color[0] / 255, green: color[1] / 255, blue: color[2] / 255, alpha: 1)

final class Field: NSView {
  var phase: CGFloat = 0
  override func draw(_ dirtyRect: NSRect) {
    fill.setFill()
    bounds.fill()
    // The moving bar stays in the middle band, so the corners and edges hold the flat colour.
    NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1).setFill()
    NSRect(x: 120 + phase * (bounds.width - 300), y: bounds.midY - 20, width: 60, height: 40).fill()
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let window = NSWindow(
  contentRect: NSRect(x: 120, y: 160, width: 480, height: 320), styleMask: [.titled, .closable],
  backing: .buffered, defer: false)
window.title = title
let field = Field(frame: window.contentView!.bounds)
field.autoresizingMask = [.width, .height]
window.contentView!.addSubview(field)
window.orderFrontRegardless()

Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
  field.phase = (field.phase + 0.02).truncatingRemainder(dividingBy: 1)
  field.needsDisplay = true
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
  print("{\"window\":\(window.windowNumber)}")
  fflush(stdout)
}
Thread.detachNewThread {
  while let line = readLine() {
    let parts = line.split(separator: " ")
    if parts.count == 3, parts[0] == "move", let dx = Double(parts[1]), let dy = Double(parts[2]) {
      DispatchQueue.main.async {
        // AppKit's y grows upward; "down" on screen is a smaller y.
        var origin = window.frame.origin
        origin.x += dx
        origin.y -= dy
        window.setFrameOrigin(origin)
        print("{\"moved\":true}")
        fflush(stdout)
      }
    }
  }
  exit(0)
}
app.run()
