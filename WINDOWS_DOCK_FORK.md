# Personal Windows-style Dock fork

Based on upstream DockDoor **1.39.4** (`efc9ddc9e0957171a4a460b9c20381a223f53465`), GPL-3.0-or-later. The existing thumbnail UI is reused, not replaced with another chooser.

## Click previews

The existing hover preview still uses its normal open/leave delays. A physical grouped Dock click can request the same UI with:

```applescript
tell application "DockDoor" to show preview "com.microsoft.edgemac" by "bundle" persistent true dock frame "400,940,60,60"
```

`dock frame` and `at` use Quartz global coordinates (origin at the primary display's upper-left). Click previews use the actual Dock orientation and remain open when the pointer leaves. They ignore other icons' hover notifications until dismissed. Selecting a thumbnail, clicking outside, pressing Escape, changing Space/focused app, terminating the target app, or clicking the same group again dismisses them. Native thumbnail context menus remain usable.

The dismissal event tap never consumes mouse clicks. The existing Hammerspoon Dock module still owns paired short-click down/up events and native drag/hold handoff, as well as single-window minimize/restore. Its grouped-click command must include `persistent true`. No gesture or keyboard configuration is changed by this fork.

```applescript
tell application "DockDoor" to get preview state
```

This read-only JSON reports visibility, persistence, owner, window count, dismissal-tap status and build commit. It contains no preview images or window titles.

## Build and deployment

The owner authorized the `Windows Dock custom build` GitHub Actions workflow. It tests the project, packages an ARM64 release and applies an ad-hoc signature. It needs no account secrets or signing certificate. Preserve the upstream app and preferences before installing. A changed code signature can require renewed macOS Accessibility and Screen Recording approval; never bypass those checks.

The custom build does not start Sparkle's upstream updater, so an upstream update cannot silently overwrite these changes. Rebuild the fork to update it. The upstream GPL license is retained. No upstream pull request is created automatically.

## Verification

`DockClickPreviewStateTests` covers toggle, outside-click geometry, stale asynchronous work, hover protection and multi-monitor coordinate conversion. These unit tests are not a substitute for physical input tests:

1. Hover over a group: thumbnails appear and fade using the existing grace period.
2. Click a group: no window activates; moving away leaves its thumbnails visible.
3. Choose a window, click outside, press Escape, or click the same icon again: thumbnails close.
4. A neighboring icon's hover cannot steal a clicked group. Clicking a different group replaces it.
5. Single-window click minimize/restore, genuine right-click, stationary hold and native Dock drag reordering remain unchanged.
6. All mouse/trackpad directions and multi-finger gestures remain unchanged.
