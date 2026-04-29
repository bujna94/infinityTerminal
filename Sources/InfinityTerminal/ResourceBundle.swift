import Foundation

/// Safe replacement for `Bundle.module` that works both in development
/// (`swift run`) and inside a packaged `.app` bundle.
///
/// SPM's auto-generated `Bundle.module` for executable targets uses
/// `fatalError` when the resource bundle isn't found at the expected path,
/// which crashes the app when it's launched from /Applications.
extension Bundle {
    static let appResources: Bundle = {
        let bundleName = "InfinityTerminal_InfinityTerminal"

        // 1. Inside a .app bundle: Contents/Resources/<name>.bundle
        if let url = Bundle.main.url(forResource: bundleName, withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }

        // 2. Development (swift run): next to the executable
        if let exe = Bundle.main.executableURL {
            let sibling = exe.deletingLastPathComponent()
                .appendingPathComponent("\(bundleName).bundle")
            if let bundle = Bundle(url: sibling) {
                return bundle
            }
        }

        // 3. Fallback — use main bundle itself
        return Bundle.main
    }()
}
