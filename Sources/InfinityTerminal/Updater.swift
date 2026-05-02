import AppKit
import Sparkle

/// Thin wrapper around Sparkle's standard updater controller.
///
/// The actual feed URL and EdDSA public key live in Info.plist (set by
/// build-app.sh) — Sparkle reads them from `SUFeedURL` and `SUPublicEDKey`.
/// See SPARKLE_SETUP.md for one-time setup steps (key generation, appcast
/// hosting) that have to happen outside this file.
final class Updater: NSObject {
    let controller: SPUStandardUpdaterController

    override init() {
        // startingUpdater: true → Sparkle starts its scheduled background
        // checks immediately. The cadence is controlled by the user via the
        // standard "Automatically check for updates" preference, which
        // Sparkle persists to UserDefaults under the key SUEnableAutomaticChecks.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    /// Hook target for the "Check for Updates…" menu item. Sparkle handles
    /// the rest: shows progress, downloads the new DMG, verifies signature,
    /// prompts to install + relaunch.
    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
