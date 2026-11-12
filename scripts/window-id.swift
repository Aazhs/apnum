// Prints the CoreGraphics window id of the largest window owned by a process id.
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let mine = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
let largest = mine.max { a, b in
    func area(_ w: [String: Any]) -> Double {
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return (b["Width"] ?? 0) * (b["Height"] ?? 0)
    }
    return area(a) < area(b)
}
if let id = largest?[kCGWindowNumber as String] as? Int { print(id) } else { exit(1) }
