#!/bin/bash
# Probes how BetterTouchTool handles red-button clicks. Run in Terminal:
#     bash tools/btt-probe.sh
# Takes about 3 minutes and asks you to click a few things.
# Writes everything to ~/Desktop/btt-probe-report.txt
# Requires the Xcode Command Line Tools (xcode-select --install).

REPORT="$HOME/Desktop/btt-probe-report.txt"
WORK="$(mktemp -d)"
: > "$REPORT"
say_() { echo "$@" | tee -a "$REPORT"; }
ask() { # ask "question" -> records the typed answer
    local answer
    echo
    read -r -p "$1 " answer
    echo "Q: $1" >> "$REPORT"
    echo "A: $answer" >> "$REPORT"
}

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode Command Line Tools are missing. Run: xcode-select --install"
    exit 1
fi

BTT_PID="$(pgrep -x BetterTouchTool | head -1)"
if [[ -z "$BTT_PID" ]]; then
    echo "BetterTouchTool is not running. Start it and run this again."
    exit 1
fi
BTT_BIN="$(ps -o comm= -p "$BTT_PID")"
say_ "macOS $(sw_vers -productVersion), $(uname -m)"
say_ "BetterTouchTool pid $BTT_PID"
say_ "Binary: $BTT_BIN"
say_ "Version: $(defaults read "${BTT_BIN%/Contents/MacOS/*}/Contents/Info" CFBundleShortVersionString 2>/dev/null)"

# ---------------------------------------------------------------- step 1
cat > "$WORK/taps.swift" <<'EOF'
import AppKit
var count: UInt32 = 0
CGGetEventTapList(0, nil, &count)
var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
CGGetEventTapList(count, &taps, &count)
for t in taps.prefix(Int(count)) {
    let name = NSRunningApplication(processIdentifier: t.tappingProcess)?.localizedName ?? "pid \(t.tappingProcess)"
    let kind = t.options == .defaultTap ? "ACTIVE     " : "listen-only"
    let mask = t.eventsOfInterest
    let down = mask & 0x2 != 0 ? "leftDown " : ""
    let up = mask & 0x4 != 0 ? "leftUp " : ""
    let keys = mask & 0xC00 != 0 ? "keys " : ""
    print("  \(name) | \(kind) | enabled=\(t.enabled) | \(down)\(up)\(keys)(mask 0x\(String(mask, radix: 16)))"
        + " | latency ms min/avg/max: \(Double(t.minUsecLatency) / 1000) / \(Double(t.avgUsecLatency) / 1000) / \(Double(t.maxUsecLatency) / 1000)")
}
if count == 0 { print("  (no event taps installed)") }
EOF
echo "Compiling the tap lister..."
if ! swiftc -O -o "$WORK/taps" "$WORK/taps.swift" 2>> "$REPORT"; then
    say_ "Could not compile the tap lister; see errors above in the report."
fi
list_taps() { [[ -x "$WORK/taps" ]] && "$WORK/taps" | tee -a "$REPORT"; }

say_
say_ "== 1. Event taps right now (ACTIVE = can block or delay clicks) =="
list_taps

# ---------------------------------------------------------------- step 2
say_
say_ "== 2. Frozen-app test =="
echo "probe" > "$WORK/btt-probe-test.txt"
open -a TextEdit "$WORK/btt-probe-test.txt"
sleep 3
TE_PID="$(pgrep -x TextEdit | head -1)"
if [[ -z "$TE_PID" ]]; then
    say_ "TextEdit did not start; skipping."
else
    trap 'kill -CONT "$TE_PID" 2>/dev/null' EXIT
    echo
    echo "TextEdit will be frozen for 25 seconds. During that time:"
    echo "  - click the red button of the TextEdit window 3 times"
    echo "  - click in the middle of the TextEdit window 3 times"
    echo "  - click on another app's window and watch whether clicks or the pointer lag"
    read -r -p "Press Return to freeze TextEdit and start..." _
    kill -STOP "$TE_PID"
    for s in 25 20 15 10 5; do echo "  $s seconds left"; sleep 5; done
    kill -CONT "$TE_PID"
    echo "TextEdit is running again."
    say_ "Event taps after the frozen-app clicks:"
    list_taps
    ask "Did clicks or the pointer lag while TextEdit was frozen? (no / a little / several seconds)"
    ask "After unfreezing, did TextEdit close its window or quit? (nothing / closed / quit)"
fi

# ---------------------------------------------------------------- step 3
say_
say_ "== 3. Behavior checks (do each, then type what happened) =="
echo "For each check, use an app your BetterTouchTool red-button rule applies to."
ask "PRESS OR RELEASE: with one window open, press the red button, keep holding, drag off it, release. What happened? (nothing / closed / quit)"
ask "OTHER SPACES: put one window of an app in full screen and one on the desktop, then red-button the desktop one. Did the app quit, taking the full-screen window with it? (yes / no)"
ask "SAVE PROMPT: type into a new unsaved document, red-button it, press Cancel on the prompt. Is the app still running with the document open? (yes / no)"
ask "BACKGROUND WINDOW: with app A in front, red-button app B's only window without activating B first. What happened? (B quit / B window closed only / A was affected)"

# ---------------------------------------------------------------- step 4
say_
say_ "== 4. System functions the binary refers to =="
PATTERN='CGEventTapCreate|CGEventTapEnable|CGGetEventTapList|AXUIElementSetMessagingTimeout|AXUIElementCopyElementAtPosition|AXUIElementCopyAttributeValue|AXObserverCreate|_AXUIElementGetWindow|(CGS|SLS)CopySpacesForWindows|CGSMainConnectionID|SLSMainConnectionID|CGWindowListCopyWindowInfo|addGlobalMonitorForEvents|IOHIDManagerCreate'
say_ "Imported directly (nm -u):"
nm -u -arch "$(uname -m)" "$BTT_BIN" 2>/dev/null | grep -E "$PATTERN" | sort -u | sed 's/^/  /' | tee -a "$REPORT"
say_ "Mentioned anywhere in the binary (covers run-time lookups and method names):"
strings -a "$BTT_BIN" | grep -E "^_?($PATTERN)" | sort -u | head -60 | sed 's/^/  /' | tee -a "$REPORT"

rm -rf "$WORK"
echo
echo "Done. Report saved to $REPORT — paste its contents back into the chat."
