#!/bin/bash
# Measures how long each click is held up before it is delivered, first with TextEdit
# running normally, then with TextEdit frozen. Prints a line for every click.
#     bash tools/btt-clicklag.sh
# Writes the results to ~/Desktop/btt-clicklag-report.txt
# Requires the Xcode Command Line Tools.

REPORT="$HOME/Desktop/btt-clicklag-report.txt"
WORK="$(mktemp -d)"
: > "$REPORT"

cat > "$WORK/clicklag.swift" <<'EOF'
import AppKit

let label = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "test"
let seconds = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 20) : 20
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var delays: [Double] = []

// Name of the app whose window is under the point (top-left screen coordinates).
func ownerUnder(_ point: CGPoint) -> String {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else { return "?" }
    for info in list {
        guard (info[kCGWindowLayer as String] as? Int) == 0,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dict as CFDictionary),
              rect.contains(point) else { continue }
        return (info[kCGWindowOwnerName as String] as? String) ?? "?"
    }
    return "desktop/other"
}

_ = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
    // event.timestamp is when the click was made; now is when it was delivered.
    let ms = (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
    let location = NSEvent.mouseLocation
    let height = NSScreen.screens.first?.frame.height ?? 0
    let owner = ownerUnder(CGPoint(x: location.x, y: height - location.y))
    let kind = event.type == .leftMouseDown ? "down" : "up  "
    delays.append(ms)
    print("  click \(kind)  held \(String(format: "%8.1f", ms)) ms   on \(owner)")
    fflush(stdout)
}

DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    let sorted = delays.sorted()
    if let worst = sorted.last {
        let median = sorted[sorted.count / 2]
        print("  [\(label)] \(sorted.count) events, median \(String(format: "%.1f", median)) ms, worst \(String(format: "%.1f", worst)) ms")
    } else {
        print("  [\(label)] no clicks seen")
    }
    fflush(stdout)
    exit(0)
}
app.run()
EOF

echo "Compiling..."
if ! swiftc -O -o "$WORK/clicklag" "$WORK/clicklag.swift" 2>&1 | tee -a "$REPORT"; then :; fi
if [[ ! -x "$WORK/clicklag" ]]; then
    echo "Compile failed; paste the errors above into the chat."
    exit 1
fi

echo "probe" > "$WORK/clicklag-test.txt"
open -a TextEdit "$WORK/clicklag-test.txt"
sleep 3
TE_PID="$(pgrep -x TextEdit | head -1)"
if [[ -z "$TE_PID" ]]; then echo "TextEdit did not start."; exit 1; fi
trap 'kill -CONT "$TE_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

echo
echo "PART 1 of 2 - TextEdit running normally (15 seconds)."
echo "  Click a few times in the middle of the TextEdit window and on another app's window."
echo "  Do NOT click the red button yet. Each click should print a line here."
read -r -p "Press Return to start..." _
echo "== Part 1: TextEdit running normally ==" | tee -a "$REPORT"
"$WORK/clicklag" "normal" 15 | tee -a "$REPORT"

echo
echo "PART 2 of 2 - TextEdit frozen (25 seconds)."
echo "  - click TextEdit's red button 3 times"
echo "  - click in the middle of the TextEdit window 3 times"
echo "  - click on another app's window 3 times"
read -r -p "Press Return to freeze TextEdit and start..." _
kill -STOP "$TE_PID"
echo "== Part 2: TextEdit frozen ==" | tee -a "$REPORT"
"$WORK/clicklag" "frozen" 25 | tee -a "$REPORT"
kill -CONT "$TE_PID"

echo
echo "TextEdit is running again. Results saved to $REPORT - paste them into the chat."
