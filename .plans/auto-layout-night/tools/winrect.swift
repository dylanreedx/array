import CoreGraphics
import Foundation
// usage: winrect <pid>  -> prints x,y,w,h of the largest on-screen window of pid
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
var best: CGRect = .zero
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    if let b = w[kCGWindowBounds as String] as? [String: CGFloat] {
        let r = CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
        if r.width * r.height > best.width * best.height { best = r }
    }
}
print("\(Int(best.minX)),\(Int(best.minY)),\(Int(best.width)),\(Int(best.height))")
