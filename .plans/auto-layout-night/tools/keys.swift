import ApplicationServices
import Foundation
// usage: keys trusted | keys cmdk | keys type <text> | keys enter
let args = CommandLine.arguments
func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .hidSystemState)
    let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)!; d.flags = flags; d.post(tap: .cghidEventTap)
    let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)!; u.flags = flags; u.post(tap: .cghidEventTap)
    usleep(40_000)
}
switch args[1] {
case "trusted": print(AXIsProcessTrusted())
case "cmdk": key(40, .maskCommand)
case "optcmdt": key(17, [.maskCommand, .maskAlternate])
case "enter": key(36)
case "esc": key(53)
case "type":
    let src = CGEventSource(stateID: .hidSystemState)
    for ch in args[2].utf16 {
        let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!; var c = ch; d.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); d.post(tap: .cghidEventTap)
        let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)!; u.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); u.post(tap: .cghidEventTap)
        usleep(60_000)
    }
default: break
}
