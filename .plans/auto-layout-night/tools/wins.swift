import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list { let o = w[kCGWindowOwnerName as String] as? String ?? "?"; let n = w[kCGWindowName as String] as? String ?? ""; let l = w[kCGWindowLayer as String] as? Int ?? 0
  if l >= 0 && o != "Window Server" { print(o, "|", n, "| layer", l, "| pid", w[kCGWindowOwnerPID as String] ?? 0) } }
