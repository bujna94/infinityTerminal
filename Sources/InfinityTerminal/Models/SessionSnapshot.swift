import Foundation
import AppKit

// MARK: - Codable snapshot types
//
// Live model objects (TerminalSession, TerminalColumn, TerminalGridModel)
// hold non-Codable state (NSView caches, SwiftUI publishers, etc.). For
// persistence we project them into these plain-data structs.

struct ColorSnapshot: Codable, Equatable {
    var hue: CGFloat
    var saturation: CGFloat
    var brightness: CGFloat
    var alpha: CGFloat

    init?(_ color: NSColor?) {
        guard let color else { return nil }
        let c = color.usingColorSpace(.sRGB) ?? color
        self.hue = c.hueComponent
        self.saturation = c.saturationComponent
        self.brightness = c.brightnessComponent
        self.alpha = c.alphaComponent
    }

    var nsColor: NSColor {
        NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
    }
}

struct TerminalSessionSnapshot: Codable, Equatable {
    var color: ColorSnapshot?
    var cwd: String?
}

struct TerminalColumnSnapshot: Codable, Equatable {
    var sessions: [TerminalSessionSnapshot]
}

struct GridSnapshot: Codable, Equatable {
    /// Bumped when the on-disk format changes; older versions are discarded.
    static let currentVersion = 1
    var version: Int = currentVersion
    var columns: [TerminalColumnSnapshot]
    var homeColumnIndex: Int?
    var fontSize: CGFloat
    var activeColumn: Int?
    var activeSession: Int?
    /// Horizontal scroll offset of the column grid at save time.
    var scrollLeft: CGFloat?
}
