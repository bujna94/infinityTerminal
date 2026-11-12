## What's Changed
- **⌘-clicked links are checked before they open.** A program can print a link whose visible text differs from where it really goes. Web and email links still open straight away; anything else, such as a `file://` link or one that launches another app, now asks first and shows the full address.
- **Tighter code signing.** The app no longer allows loading code libraries that aren't signed by its developer. It never needed that exception, and macOS's protections now apply in full.
- **Hardened release pipeline.** The signing identity is deleted from the build machine as soon as the app is signed, build steps are pinned to exact versions, and release notes are escaped before they reach infinityterminal.com.
