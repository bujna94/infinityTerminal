## What's Changed
- **Microphone access now actually works.** Added the `com.apple.security.device.audio-input` entitlement; under Hardened Runtime, `NSMicrophoneUsageDescription` alone wasn't enough for macOS to even show the permission prompt, so terminal programs needing audio (e.g. Claude Code's `/voice`) were being silently denied.
