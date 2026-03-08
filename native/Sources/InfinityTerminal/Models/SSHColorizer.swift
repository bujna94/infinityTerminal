import AppKit

struct SSHColorizer {
    /// FNV-1a hash to produce a deterministic HSB color for an SSH hostname.
    /// Uses saturation 0.35 and brightness 0.17 to match the original Electron app.
    static func backgroundColor(for host: String) -> NSColor {
        var hash: UInt32 = 2166136261
        for byte in host.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        var hue = Double(hash % 360) / 360.0
        // Nudge hue if it falls too close to the default blue-gray background hue (+37° collision avoidance).
        let defaultHue = 228.0 / 360.0
        if abs(hue - defaultHue) < 0.05 {
            hue = (hue + 37.0 / 360.0).truncatingRemainder(dividingBy: 1.0)
        }
        return NSColor(hue: CGFloat(hue), saturation: 0.35, brightness: 0.17, alpha: 1.0)
    }

    static let defaultBackground = NSColor(red: 0.059, green: 0.067, blue: 0.090, alpha: 1.0)
}
