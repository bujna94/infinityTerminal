## What's Changed
- **Option key now types `#` and other ⌥-composed characters.** SwiftTerm treated Option as a Meta key by default, so `⌥3` sent an `ESC` sequence instead of `#` (and `⌥2` → `€`, etc.) on UK/international layouts. Option now types the composed character, matching Terminal.app.
- **New "⌥ Meta" toggle.** A toolbar button (and `⌘⌥O` shortcut) lets you switch Option back to a Meta key when you want `⌥B`/`⌥F` word-jump and other ESC sequences. The choice is remembered across launches.
