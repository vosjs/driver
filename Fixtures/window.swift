// A window for the tests to record: titled, 480 x 320 of content, with a bar that moves so
// the capture has frames. It takes no focus and shows no Dock icon.
//
// It prints {"window": <id>} once it is on screen, and exits when stdin closes.
import AppKit

final class Bar: NSView {
  var phase: CGFloat = 0
  override func draw(_ dirtyRect: NSRect) {
    NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1).setFill()
    bounds.fill()
    NSColor(red: 0.81, green: 0.36, blue: 0.26, alpha: 1).setFill()
    NSRect(x: phase * (bounds.width - 60), y: bounds.midY - 20, width: 60, height: 40).fill()
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let window = NSWindow(
  contentRect: NSRect(x: 120, y: 160, width: 480, height: 320), styleMask: [.titled, .closable],
  backing: .buffered, defer: false)
window.title = "vos-driver fixture"
let bar = Bar(frame: window.contentView!.bounds)
bar.autoresizingMask = [.width, .height]
window.contentView!.addSubview(bar)
window.orderFrontRegardless()

Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
  bar.phase = (bar.phase + 0.02).truncatingRemainder(dividingBy: 1)
  bar.needsDisplay = true
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
  print("{\"window\":\(window.windowNumber)}")
  fflush(stdout)
}
Thread.detachNewThread {
  while readLine() != nil {}
  exit(0)
}
app.run()
