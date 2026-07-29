#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

guard let screen = NSScreen.main,
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
    fputs("retina-main check failed: NSScreen.main unavailable\n", stderr)
    exit(1)
}

let displayID = CGDirectDisplayID(number.uint32Value)
let builtin = CGDisplayIsBuiltin(displayID) != 0
let scale = screen.backingScaleFactor

guard builtin, scale >= 2.0 else {
    fputs("retina-main check failed: main display id=\(displayID) builtin=\(builtin) backingScale=\(scale)\n", stderr)
    exit(1)
}

print("retina-main check: ok (display=\(displayID), backingScale=\(scale))")
