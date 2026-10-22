# Contributing to Flick

Thanks for helping. This page covers what you need to build Flick, check your changes and open a pull request.

## Setup

You need macOS 14 or later to run Flick, and the macOS 26 SDK to build it (Xcode 26, or the matching Command Line Tools). There are no dependencies to install.

```sh
scripts/make-signing-identity.sh   # once: a local signing certificate so permissions survive rebuilds
make run                           # build build/Flick.app and launch it
```

Grant Accessibility (and optionally Screen Recording) when Flick asks. With the signing identity in place you only do this once. Without it, each build is signed ad hoc and macOS treats it as a new app. If permissions ever get stuck, `tccutil reset All io.github.tom0211.flick` clears them.

Other targets: `make build` (just `swift build`), `make install` (copy to /Applications), `make icon` (regenerate the app icon from `scripts/icon.swift`), `make clean`.

## Checking your changes

The switcher is driven by a global keyboard tap and a panel that never takes focus, which makes it awkward to test by hand. These helpers make it easier:

| Command | What it does |
| --- | --- |
| `swift run Flick --list` | Prints the window list the switcher would show right now, with each window's state. Use it for any change to window discovery or ordering. |
| `swift run Flick --render out.png --demo` | Renders the panel's layout offscreen with synthetic windows. It's quick and needs no permissions, but can't show glass. |
| `open -n build/Flick.app --args --snapshot /tmp/flick --demo --backdrop` | Shows the real panel for about two seconds and saves window captures: `-1.png` as shown, `-2…-6.png` across a selection move, `-context.png` over a backdrop. Add `--light` or `--dark` to force the appearance. This is the way to check glass, colour or animation changes. |

`docs/screenshot-light.png` and `docs/screenshot-dark.png` are `-context.png` captures from `--snapshot … --demo --backdrop --light|--dark`. Regenerate them if your change affects how the panel looks.

There is no automated test suite yet. Before opening a pull request, at least:

- Tap ⌥⇥ quickly: it should switch to the previous window without showing the panel.
- Hold ⌥ and press ⇥ a few times: the selection should move, and releasing ⌥ should focus that window.
- Try a minimized window, a hidden app's window, and (if you use them) a window on another Space or display.
- Try <kbd>esc</kbd>, plus <kbd>W</kbd> / <kbd>M</kbd> / <kbd>H</kbd> / <kbd>Q</kbd> on a window you don't mind closing.

## Guidelines

- **Match the surrounding code.** Comments explain *why*, not what. Keep names plain and descriptive.
- **No dependencies** unless there's a strong case. Flick is small and self-contained on purpose.
- **Private APIs:** load them through `PrivateAPI` with `dlsym` and handle their absence, so a future macOS can only disable a feature, never stop the app launching.
- **Keep both looks working.** Anything that uses macOS 26 APIs (Liquid Glass) needs a fallback for macOS 14–15 behind `#available`.
- **Performance matters.** Opening the switcher should feel instant. Avoid extra Accessibility round trips per window, and keep slow work off the keyboard tap's callback.
- Keep pull requests focused, and describe what you checked and on which macOS version.

## Reporting bugs

Please include your macOS version, which permissions Flick has, and steps to reproduce. For window-list problems, the output of `swift run Flick --list` helps a lot. It contains your window titles, so redact anything private before posting.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
