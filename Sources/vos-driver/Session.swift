// What the take needs of the session it runs in: a display that stays awake, a screen that is
// not locked, and the appearance the picture was made in.
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Holds the display awake for as long as it lives. A take that waits sends no input, so the
/// system counts the wait as idle: the display sleeps, the screen locks, and the next take
/// cannot bring its app forward until a person unlocks it. The assertion is the one
/// `caffeinate -d` takes; it ends with the take, and with the process if the take never ends.
final class Awake {
  private var id: IOPMAssertionID = 0
  private(set) var held = false

  init() {
    let reason = "vos-driver is recording a take" as CFString
    held =
      IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
        reason, &id) == kIOReturnSuccess
  }

  func release() {
    guard held else { return }
    IOPMAssertionRelease(id)
    held = false
  }
}

/// True when the screen is locked: the login window holds the front, no app can be brought
/// forward, and input goes nowhere a script means.
func screenIsLocked() -> Bool {
  guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
  return session["CGSSessionScreenIsLocked"] as? Bool ?? false
}

let SCREEN_LOCKED =
  "The screen is locked, so the app cannot be brought to the front and a script's input would go nowhere. Unlock it and run this again."

/// The system's appearance, which apps follow: "dark" or "light". A film cut from takes made
/// under both does not match itself, so each take says which it was.
func systemAppearance() -> String {
  let style = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String
  return style?.lowercased() == "dark" ? "dark" : "light"
}
