import ApplicationServices
import Foundation
let map: [Character: CGKeyCode] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46," ":49]
let src = CGEventSource(stateID: .hidSystemState)
for ch in CommandLine.arguments[1] {
    guard let code = map[ch] else { continue }
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)!.post(tap: .cghidEventTap); usleep(30_000)
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)!.post(tap: .cghidEventTap); usleep(70_000)
}
