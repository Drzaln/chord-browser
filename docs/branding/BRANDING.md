# Chord Browser — Brand

The project's user-facing name is **Chord**. The built app is `Chord.app` with a
`Chord` executable (`PRODUCT_NAME = Chord`). The Xcode **target/scheme** name and
the **bundle id** stay `Browser` / `com.rizal.browser` — see below.

## Icon

The icon is a gradient circle cut by a white **chord** — a straight line across
the circle, the geometric "chord" the name plays on. Source of truth:
[`chord-icon.svg`](chord-icon.svg). A rendered 1024px master is
[`chord-icon-1024.png`](chord-icon-1024.png).

## Colors

| Token    | Hex                                          | Use                                        |
| -------- | -------------------------------------------- | ------------------------------------------ |
| Coral    | `#FF512F`                                    | gradient start (top-left)                  |
| Magenta  | `#DD2476`                                    | gradient end (bottom-right)                |
| Gradient | `linear-gradient(135deg, #FF512F → #DD2476)` | primary brand fill                         |
| Chord    | `#FFFFFF`                                    | the dividing line / accent on the gradient |

## How the name is applied

- **App name / filename** — `PRODUCT_NAME = Chord` (project.pbxproj) → the bundle
  is `Chord.app` and the executable/process is `Chord`.
- **Display name** — `CFBundleName` / `CFBundleDisplayName = "Chord"` in
  `BrowserApp/Info.plist` (menu bar, Finder, Dock), and the window title in
  `BrowserApp/BrowserApp.swift`.
- **Not changed on purpose:**
  - **Bundle identifier** stays `com.rizal.browser`. It keys the on-disk profile
    (cookies, Spaces, extensions, granted permissions). Changing it orphans all
    existing user data.
  - **Xcode target and scheme** stay named `Browser` — the scheme is referenced
    by `scripts/prepush.sh` (`-scheme Browser`) and renaming it is invasive for
    no user-visible gain (`PRODUCT_NAME` already controls the app's name).

## App icon — wiring (one manual Xcode step)

A ready `AppIcon.appiconset` is generated at
`BrowserApp/Assets.xcassets/AppIcon.appiconset`. To make the build use it:

1. In Xcode, add the `BrowserApp/Assets.xcassets` catalog to the **Browser**
   target (drag it in, or File → Add Files, ensuring target membership).
2. Set the target's **App Icon Set** to `AppIcon` (General → App Icons, or the
   `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` build setting).

These are project-file (`project.pbxproj`) changes, which this repo's workflow
excludes from automated commits — hence the manual step.

> Note: the icon is a **circle on transparent**. macOS masks app icons to a
> rounded square, so it will appear as a circle floating inside the squircle. If
> you want it to fill the tile, put the gradient on a full-bleed rounded-square
> background and keep the white chord on top — say the word and it's a quick
> variant.
