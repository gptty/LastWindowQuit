# LastWindowQuit

Click the red close button on an app's **last** window and the app quits, like
BetterTouchTool's "quit if it's the last window" behavior. Closing any other
window works exactly as before.

One Swift file, no dependencies, about 600 lines.

## Why this one

| | LastWindowQuit |
|---|---|
| **Debuggable log** | **Every decision is logged with its reason. When an app is *not* quit, each window that kept it alive is listed with its title, type, size, position and whether it has a close button. Paste the log into an AI assistant and it can tell you what went wrong and how to change the code.** |
| **Waits for the window to really close** | The click goes through untouched; the app closes its own window first. Quit is requested only after the window is gone, so pressing **Cancel** on a "Save changes?" prompt leaves the app running. |
| **Checks other Spaces** | Won't quit while the app still has a window on another desktop, in full screen, minimized or hidden. |
| **Red button only** | Cmd+W on the last tab never quits your browser. |
| **Fast on a frozen app** | A window-server check skips clicks outside window corners, so a hung app never delays them. Corner clicks wait at most 50 ms. |
| **One permission** | Accessibility only. |
| **Release to trigger** | Drag off the button before releasing to cancel, as macOS does natively. |
| **Works on background windows** | The app you close doesn't need to be in front. |
| **Polite** | A normal Quit request, never a force quit. Menu bar and background-only apps are ignored. |

### The log in practice

The log lives at `~/Library/Logs/LastWindowQuit.log` (or **Open Log** from the
menu bar icon) and trims itself to the newest 300 lines. A real example: ChatGPT
wouldn't quit while its desktop pet was showing. The log said why:

```
ChatGPT: 1 window(s) here, 1 on other Spaces/minimized/hidden, not quitting
    here: "ChatGPT" AXDialog 1408x881 at 0,0
    elsewhere: #445 "" 1135x758 at 147,-759
```

That identified both culprits — a screen-sized transparent canvas for the pet,
and the "closed" main window parked above the top of the screen — and led
directly to the two rules that now ignore them.

## How other tools do it

| Tool | Approach | Good | Downsides |
|---|---|---|---|
| **BetterTouchTool** (paid, closed source) | Intercepts every mouse-down and asks the app under the cursor what was clicked, before the click is delivered. Last-window quit is done with a user script on its red-button trigger. | Mature and widely used; 50 ms timeout on the app query; mouse-up never delayed | Script workarounds, not a built-in feature; forum users report scripts acting on the frontmost app instead of the clicked one; adds ~5 ms to every mouse-down; no position filtering, so every click on a frozen app's window waits 50 ms |
| [SmartClose](https://github.com/mahirozdin/SmartClose) | Intercepts the red-button mouse-down, counts windows, and if it's the last one swallows the click and quits | Actively maintained, notarized releases, tests; conservative window classification; optional Cmd+W | Acts on mouse-down, so it can't be cancelled; quits with the window still open; counts only the current Space, so likely quits an app with a window on another desktop; no query timeout (macOS default is several seconds); needs Input Monitoring as well |
| [Swift Quit](https://github.com/onebadidea/swiftquit) | Watches window-destroyed events in every app; quits when none are left, after a 2 s delay | Catches any way of closing; never in the click path; most popular (Homebrew cask) | Cmd+W on the last tab quits the app; anything that briefly has zero windows can be caught; relies on three third-party libraries (Swindler, AXSwift, PromiseKit) |
| [Hush](https://github.com/jspw/Hush) | Polls the frontmost app every 2 s and checks apps as they're deactivated; quits any regular app with zero windows | Never in the click path; "recently quit" list with undo | Quits apps you never closed a window in, guarded by grace periods; per its README ~130 MB RAM at idle |
| RedQuits, Red X Quit, Last Window Quits, TrueClose, Quitly | Closed source or not reviewed | — | — |

## BetterTouchTool experiment

How BetterTouchTool handles a hung app, measured on one Mac with
[`tools/btt-clicklag.sh`](tools/btt-clicklag.sh): TextEdit was frozen with
`kill -STOP`, then clicked while a listener timed how long each click was held
before delivery.

| Running | Normal mouse-down | Mouse-down on frozen app | Mouse-up |
|---|---|---|---|
| BetterTouchTool + BetterMouse | 6–7 ms | **~54 ms**, anywhere in the window | 1–2 ms |
| BetterTouchTool only | 3–6 ms | **~54 ms**, anywhere in the window | 1–2 ms |
| Nothing | 1–2 ms | 1–4 ms | 1–2 ms |
| **LastWindowQuit** | 3–6 ms | **~55 ms on the red-button corner, 3–4 ms elsewhere** | 1–2 ms |

Findings:

- BetterTouchTool queries the app under the cursor on **every mouse-down**, with a
  timeout of about **50 ms**. Quitting it removes the delay; quitting BetterMouse
  doesn't.
- It doesn't filter by position: a click in the middle of a frozen window waits
  as long as a click on its red button.
- Its event-tap list (from [`tools/btt-probe.sh`](tools/btt-probe.sh)) shows an
  enabled, active interceptor on left mouse-down and mouse-up.
- LastWindowQuit matches the 50 ms timeout and, thanks to the position check,
  only pays it for corner clicks.

## Install

Requires the Xcode Command Line Tools (`xcode-select --install`).

    bash build.sh            # build, install to ~/Applications, start
    bash build.sh --login    # same, and start at every login
    bash build.sh --remove   # uninstall

On first run, allow LastWindowQuit under System Settings > Privacy & Security >
Device Control and Data Access (called Accessibility on older macOS). The app is
signed ad hoc, so after every rebuild remove its old entry from that list and
add it again.

## Settings

`~/.config/lastwindowquit/config.json` is created on first run and re-read
automatically when it changes:

    {
      "exclude": ["com.apple.finder", "com.apple.mail"],
      "only": [],
      "checkOtherSpaces": true,
      "showMenuBarIcon": true,
      "positionPreFilter": true
    }

| Key | Meaning |
|---|---|
| `exclude` | Bundle IDs that are never quit |
| `only` | If not empty, only these bundle IDs are ever quit |
| `checkOtherSpaces` | Don't quit while the app has windows on other Spaces, in full screen, minimized or hidden |
| `positionPreFilter` | Only examine clicks near a window's top corner. Set to `false` if some app's red button isn't recognized |
| `showMenuBarIcon` | Show the menu bar icon (pause, settings, log) |

Find a bundle ID with `osascript -e 'id of app "Mail"'`.

## Debugging with AI

When an app doesn't behave as expected:

1. Red-button the app's window.
2. Run `tail -15 ~/Library/Logs/LastWindowQuit.log`.
3. Paste the output and `main.swift` into an AI assistant and describe what you
   expected.

The log lines name the exact rule that blocked the quit, and the code is one
file with comments explaining each rule, so the fix is usually small.

## How it works

1. A pass-through event tap sees every left mouse-down. If the click is near the
   top corner of a window (checked with the window server, never the app), one
   Accessibility query asks whether it hit a close button. 50 ms timeout.
2. On mouse-up over the same button, a background check waits for the window to
   close: up to 1.5 s, or up to 3 minutes while a save/confirm prompt is showing.
3. Once it's gone, the app is asked to quit if no real windows remain. Floating
   palettes, tiny helper windows, close-button-less overlays and windows parked
   off-screen don't count. Two empty readings in a row are required, so a window
   the app opens right after closing is not missed.

## Limitations

- Tested on one Mac. Other-Spaces detection uses two private window-server
  functions (the same ones AltTab and yabai use), looked up at run time; if a
  future macOS removes them, that check is skipped.
- Quitting after the window closes means apps relaunch without that window
  restored.

## License

MIT
