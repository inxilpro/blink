# Blink

A macOS menu bar app that reminds you to look away from the screen every ~20 minutes (the 20-20-20 rule). Unobtrusive, meeting-aware, zero-maintenance.

## How it works

Blink lives entirely in the menu bar (no dock icon, no main window) and runs a continuous cycle:

1. **Work interval** (default 20 min) counts down.
2. **Pre-break vignette** — for the last 15 s (configurable), a subtle darkened vignette fades in around the screen edges on every display.
3. **Break overlay** — the screen fades to 50% dim (configurable) with a centered countdown (default 20 s). A **Dismiss Break** pill near the bottom of each screen ends the break early.
4. The overlay fades out and the cycle restarts.

### Focus and clicks

Blink never takes keyboard focus. All overlay windows are borderless, non-activating panels that cannot become key or main, so typing continues uninterrupted into the frontmost app. Every overlay surface is click-through except the dismiss pill, which accepts clicks without activating Blink. Overlay windows also opt out of screen capture (`sharingType = .none`), so even if a share goes undetected, remote viewers never see the dim.

### Active hours and days

By default Blink runs whenever you're at the Mac. Settings can narrow that to a daily window (e.g. 9–5) and/or a set of weekdays (e.g. Mon–Fri). Outside the window the cycle parks itself entirely: no vignette, no overlay, and the menu shows when it reopens. It resumes on its own at the next window start without any polling — a single timer is armed for the next boundary. A window whose end is at or before its start runs overnight (e.g. 22:00–06:00), attributed to the day it begins on. **Take Break Now** always works, window or not.

### Automatic skips

- **Idle:** if you've been away past the threshold (default 3 min), the timer silently resets — you'll never get a break right after returning. While you're away the timer keeps rolling forward, so you always return to a full interval.
- **Lock / sleep:** locking the screen, display sleep, system sleep, or fast-user-switching cancels overlays and suspends the timer; it restarts fresh when you're back.
- **Camera in use:** if any app is capturing from any camera, breaks are deferred. Detection uses CoreMediaIO's `DeviceIsRunningSomewhere` device property — it observes state only, never video, and never triggers a camera permission prompt.
- **Microphone in use:** the same check against CoreAudio input devices. An open microphone is the most reliable public signal that a call or pairing session is in progress — conferencing apps hold the input stream open even while muted, and it covers screen sharing with the camera off. No audio is observed and no permission prompt fires.
- **Outside active hours:** if you've limited Blink to certain hours or days, breaks simply don't come due outside them. A break already on screen when the window closes is allowed to finish.
- A deferred break waits up to 10 minutes for the camera/microphone to go quiet, then is skipped and the cycle restarts. The menu bar icon switches to an hourglass as soon as a call starts, so suppression is visible before the break is even due.

### Menu bar

**Check for Updates…** appears in the menu when Sparkle is running (Release
builds only). Updates are signed and delivered through the GitHub Release
feed; see `Documentation/RELEASING.md`.

The icon reflects state: `eye` (running), `eye.fill` (break imminent/active), `eye.slash` (paused or outside your active hours), `hourglass` (break deferred by a call/share). The menu shows time until the next break plus: Take Break Now, Skip Next Break, Pause for 1 Hour / Until Tomorrow / Until Resumed, Resume, Settings, and Quit. An optional setting shows minutes remaining as menu bar text.

### Settings

Settings (⌘, from the menu) persist in `UserDefaults`: work interval, break duration, pre-break lead time, active hours and days, dim level, idle threshold, skip-during-capture toggle, launch at login (via `SMAppService`), sounds, menu bar countdown text, and the debug menu toggle.

## Architecture

AppKit lifecycle with SwiftUI for content views. Everything is composed in `AppController`.

| Component | Role |
|---|---|
| `BreakScheduler` | The state machine (working → pre-break → break, plus pause/deferral/suspension). Pure logic — reads the world via injected closures and an injectable `SchedulerClock`, reports transitions via delegate. |
| `ActiveSchedule` | Pure value type for the hours/days window: whether a moment is inside it, when the current window closes, when the next one opens. Handles overnight windows and locale weekday numbering. |
| `OverlayController` / `OverlayPanel` | Per-screen non-activating panels at screen-saver level: vignette, dim + countdown, dismiss zone. Handles fades and display reconfiguration. |
| `CameraUsageMonitor` | Event-driven CoreMediaIO property listeners for camera-in-use. |
| `MicrophoneUsageMonitor` | Event-driven CoreAudio property listeners for microphone-in-use. |
| `SystemAvailabilityMonitor` | Lock/unlock, display & system sleep, session switching — unioned so out-of-order notifications resolve correctly. |
| `SystemIdle` | Idle seconds via `CGEventSource` timestamps (no event tap, no permissions). |
| `StatusItemController` | Menu bar icon + menu. |
| `AppSettings` | `@Observable` settings persisted to `UserDefaults`. |
| `UpdaterController` | Owns the one Sparkle updater. Starts only in Release builds, so Debug runs and tests never reach the network. |

The scheduler is fully unit-tested (`BlinkTests`) against a virtual clock — cycles, idle resets, capture deferral, the deferral cap, pause/resume, system suspension, and the active hours/days window (including overnight windows and weekend gaps) are all covered deterministically.

### Design decisions & known limitations

- **App Sandbox is off** (hardened runtime stays on). The sandbox blocks CoreMediaIO device-state observation without a camera entitlement; Blink is a directly-distributed utility with no file access, network, or capture, so the trade was made in favor of reliable, prompt-free detection.
- **Call detection is camera + microphone, not screen-capture.** macOS has no public API to observe other apps' ScreenCaptureKit sessions, and process-name heuristics proved false in practice (Zoom's `caphost` helper runs for the lifetime of the app, not just during shares — it caused permanent false positives and was removed). An open camera or microphone covers real calls and pairing sessions; a silent, mic-less screen recording can slip through, and overlays are capture-excluded (`sharingType = .none`) as the safety net for exactly that case.
- **No polling loops** where events exist: camera, process, lock, and sleep signals are all notification/listener-driven. The only timers are the scheduled phase transitions, a 30 s idle housekeeping check, and a 20 s menu bar refresh — idle CPU is effectively zero.
- Changing schedule settings restarts the current work interval.

## Debugging detection

Two surfaces answer "why does Blink think I'm on a call?":

- **Menu bar → Debug** shows the live per-device state of every camera and audio input, and **Copy Diagnostics** puts a full state dump (phase, deferral state, devices, settings) on the clipboard. The submenu is hidden until **Show debug menu** is enabled in Settings.
- Every detection and scheduling decision is logged via `os.log` and persists:

  ```sh
  /usr/bin/log show --last 1h --predicate 'subsystem == "com.cmorrell.Blink"'
  /usr/bin/log stream --predicate 'subsystem == "com.cmorrell.Blink"'
  ```

## Releasing

Push a `vX.Y.Z` tag. `.github/workflows/release.yml` tests, builds, signs,
notarizes, staples, and publishes a DMG, a zip, and a signed Sparkle appcast to
the GitHub Release. `.github/workflows/ci.yml` builds and tests every push to
`main` and every PR. `Documentation/RELEASING.md` covers the secrets, the
Sparkle key, and how to verify a release.

## Building

Open `Blink.xcodeproj` in Xcode 26+ (targets macOS 15.7+) and run, or:

```sh
xcodebuild -project Blink.xcodeproj -scheme Blink build
xcodebuild -project Blink.xcodeproj -scheme Blink -destination 'platform=macOS' -only-testing:BlinkTests test
```
