# Chord Browser — Brand

The project's user-facing name is **Chord**. (Internal target,
product name, and bundle id stay `Browser` / `com.rizal.browser` — see below.)

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

- **Visible name** — `CFBundleDisplayName = "Chord"` in
  `BrowserApp/Info.plist`, and the window title in `BrowserApp/BrowserApp.swift`.
- **Not changed on purpose:**
  - **Bundle identifier** stays `com.rizal.browser`. It keys the on-disk profile
    (cookies, Spaces, extensions, granted permissions). Changing it orphans all
    existing user data, so the rebrand is display-only.
  - **Xcode target / `PRODUCT_NAME`** stays `Browser` (renaming touches the
    project file, which this repo excludes from commits, and gains nothing users
    see once `CFBundleDisplayName` is set).

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
