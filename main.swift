// LastWindowQuit — click the red close button on an app's last window and the app quits.
//
// How it works
//   1. A pass-through event tap sees every left mouse-down. If the click is near the top
//      corner of some window (checked with the window server, never the app), one
//      Accessibility hit-test asks "is this an AXCloseButton?" before the click reaches
//      the app. The click is never swallowed or modified.
//   2. If the mouse is released on that same button, a background check waits for the
//      window to actually go away (so a "Save changes?" sheet, or an app that refuses
//      to close, never leads to a quit).
//   3. Once the window is gone, the app is asked to quit (a normal, polite Quit) only if
//      it has no other real windows left: none on this Space, none minimized, and none
//      on other Spaces / in full screen.
//
// Needs only the Accessibility permission. Build with ./build.sh (see README.md).

import AppKit
import ApplicationServices

// MARK: - Logging

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/LastWindowQuit.log")
let logQueue = DispatchQueue(label: "lastwindowquit.log")
let logDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

// The log is kept short: once it grows past logTrimAt lines it is cut back to the newest
// logKeepLines. Checked at startup and then every 50 lines written. Runs on logQueue only.
let logKeepLines = 300
let logTrimAt = 400
var logWritesSinceTrim = 50 // so the first write after launch checks the file

func trimLogIfNeeded() {
    logWritesSinceTrim += 1
    guard logWritesSinceTrim >= 50 else { return }
    logWritesSinceTrim = 0
    guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    guard lines.count > logTrimAt else { return }
    let kept = lines.suffix(logKeepLines).joined(separator: "\n") + "\n"
    try? kept.write(to: logURL, atomically: true, encoding: .utf8)
}

func logLine(_ message: String) {
    logQueue.async {
        trimLogIfNeeded()
        let line = "\(logDateFormatter.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)!.write(to: logURL)
        }
    }
}

// MARK: - Configuration (~/.config/lastwindowquit/config.json)

struct Config: Codable {
    /// Bundle IDs that are never quit.
    var exclude: [String] = ["com.apple.finder"]
    /// If non-empty, ONLY these bundle IDs are ever quit (exclude is then ignored).
    var only: [String] = []
    /// Refuse to quit while the app still has windows on other Spaces / in full screen.
    var checkOtherSpaces: Bool = true
    /// Show the menu bar icon.
    var showMenuBarIcon: Bool = true
    /// Only ask the app about a click when it lands near a window's top corner.
    var positionPreFilter: Bool = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? exclude
        only = try c.decodeIfPresent([String].self, forKey: .only) ?? only
        checkOtherSpaces = try c.decodeIfPresent(Bool.self, forKey: .checkOtherSpaces) ?? checkOtherSpaces
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? showMenuBarIcon
        positionPreFilter = try c.decodeIfPresent(Bool.self, forKey: .positionPreFilter) ?? positionPreFilter
    }

    func allows(_ bundleID: String) -> Bool {
        if !only.isEmpty { return only.contains(bundleID) }
        return !exclude.contains(bundleID)
    }
}

final class ConfigStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lastwindowquit/config.json")
    private(set) var config = Config()
    private var loadedMTime: Date?

    init() {
        if !FileManager.default.fileExists(atPath: Self.url.path) { writeDefault() }
        reloadIfChanged()
    }

    private func writeDefault() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(Config()).write(to: Self.url)
        } catch {
            logLine("Could not write default config: \(error.localizedDescription)")
        }
    }

    /// Cheap enough to call on every close-button click; re-reads only when the file changed.
    func reloadIfChanged() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Self.url.path)
        let mtime = attrs?[.modificationDate] as? Date
        guard mtime != loadedMTime else { return }
        loadedMTime = mtime
        guard let data = try? Data(contentsOf: Self.url) else { return }
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
            logLine("Config loaded: exclude=\(config.exclude) only=\(config.only) checkOtherSpaces=\(config.checkOtherSpaces) positionPreFilter=\(config.positionPreFilter)")
        } catch {
            logLine("Config is not valid JSON, keeping previous settings: \(error.localizedDescription)")
        }
    }
}

// MARK: - Accessibility helpers

enum AX {
    static let systemWide = AXUIElementCreateSystemWide()

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// True only when the element definitely has no such attribute. A timeout or other
    /// failure returns false, so a slow app is never mistaken for one without the attribute.
    static func lacks(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return result == .noValue || result == .attributeUnsupported
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        value(element, attribute) as? Bool
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = value(element, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else {
            return nil
        }
        return (v as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        value(element, attribute) as? [AXUIElement]
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute as String),
              let s = value(element, kAXSizeAttribute as String),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func pid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    /// The window that contains `element`.
    static func window(of element: AXUIElement) -> AXUIElement? {
        if let w = self.element(element, kAXWindowAttribute as String) { return w }
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let node = current else { return nil }
            if string(node, kAXRoleAttribute as String) == (kAXWindowRole as String) { return node }
            current = self.element(node, kAXParentAttribute as String)
        }
        return nil
    }

    /// The app's window list, or nil if the app did not answer (treated as "unknown").
    static func windows(of pid: pid_t) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5) // off the click path, so it can afford to wait longer
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) {
        case .success: return (value as? [AXUIElement]) ?? []
        case .noValue: return []
        default: return nil
        }
    }
}

// MARK: - Windows on other Spaces (private window-server calls, looked up at run time)

/// The Accessibility API only lists windows on the current Space, so an app with one window
/// here and another in full screen looks like it is on its "last window". These two private
/// functions (the same ones AltTab and yabai rely on) tell us whether an off-screen window
/// still lives on some Space. They are resolved with dlsym, so if a future macOS removes
/// them the check is skipped instead of the program failing to launch.
enum OtherSpaces {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
    private static let mainConnection: MainConnectionFn? = {
        for name in ["CGSMainConnectionID", "SLSMainConnectionID"] {
            if let sym = dlsym(handle, name) { return unsafeBitCast(sym, to: MainConnectionFn.self) }
        }
        return nil
    }()
    private static let copySpaces: CopySpacesFn? = {
        for name in ["CGSCopySpacesForWindows", "SLSCopySpacesForWindows"] {
            if let sym = dlsym(handle, name) { return unsafeBitCast(sym, to: CopySpacesFn.self) }
        }
        return nil
    }()

    static var isAvailable: Bool { mainConnection != nil && copySpaces != nil }

    private static func isOnSomeSpace(_ windowID: Int) -> Bool {
        guard let mainConnection = mainConnection, let copySpaces = copySpaces else { return false }
        let ids = [NSNumber(value: windowID)] as CFArray
        guard let spaces = copySpaces(mainConnection(), 0x7 /* all spaces */, ids)?
            .takeRetainedValue() as? [Any] else { return false }
        return !spaces.isEmpty
    }

    /// Normal-level windows of `pid` that are not on screen right now but still belong to a
    /// Space: windows on other desktops, full-screen windows, minimized windows, and the
    /// windows of a hidden app. Windows an app merely keeps around after closing them are
    /// not attached to any Space and are not counted.
    /// Bounds of every active display, in the same coordinates as window bounds.
    private static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Returns one short description per window, for the log.
    static func offscreenWindows(of pid: pid_t) -> [String] {
        guard isAvailable,
              let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }

        let displays = displayBounds()
        var found: [String] = []
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  (info[kCGWindowIsOnscreen as String] as? Bool) != true,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 60, bounds.height >= 60,
                  let windowID = info[kCGWindowNumber as String] as? Int
            else { continue }
            // A window parked outside every display (some apps hide a closed window by moving
            // it off the edge of the screen) cannot be seen on any Space, so it does not count.
            if !displays.isEmpty {
                let visibleSomewhere = displays.contains { display in
                    let overlap = display.intersection(bounds)
                    return !overlap.isNull && overlap.width >= 10 && overlap.height >= 10
                }
                if !visibleSomewhere { continue }
            }
            if isOnSomeSpace(windowID) {
                let name = (info[kCGWindowName as String] as? String) ?? ""
                found.append("#\(windowID) \"\(name)\" \(Int(bounds.width))x\(Int(bounds.height)) at \(Int(bounds.minX)),\(Int(bounds.minY))")
            }
        }
        return found
    }
}

// MARK: - The watcher

/// A press on a close button, captured before the app saw the click.
struct PendingClose {
    let pid: pid_t
    let appName: String
    let window: AXUIElement
    let buttonFrame: CGRect
    let checkOtherSpaces: Bool
}

final class Watcher {
    var enabled = true
    private let configStore: ConfigStore
    private var tap: CFMachPort?
    private var pending: PendingClose?
    private let work = DispatchQueue(label: "lastwindowquit.verify", qos: .userInitiated)

    // Timing, in seconds.
    private let closeTimeout = 1.5        // how long a window gets to close after the click
    private let dialogTimeout = 180.0     // how long to wait on a "Save changes?" prompt
    private let lingerAllowance = 0.5     // how long stale windows may linger before we give up

    // Size of the window-corner region, in points, where a close button can be. Generous on
    // purpose: tall toolbars and apps with custom title bars place the buttons lower.
    private let cornerWidth: CGFloat = 120
    private let cornerHeight: CGFloat = 80

    init(configStore: ConfigStore) {
        self.configStore = configStore
        // Never let a hung app stall us (and, through the tap, the mouse) for long. This is
        // the most a click on an unresponsive app's window can be held up.
        AXUIElementSetMessagingTimeout(AX.systemWide, 0.05)
    }

    // MARK: Event tap

    /// Returns false if macOS refused the tap (Accessibility permission missing).
    func start() -> Bool {
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                Unmanaged<Watcher>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event) // always pass the click through untouched
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // synchronous, so the hit-test runs before the app sees the click
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            pending = enabled ? closeButtonPress(at: event.location) : nil
        case .leftMouseUp:
            guard let press = pending else { return }
            pending = nil
            // Dragging off the button before releasing cancels the close, as it does natively.
            guard press.buttonFrame.insetBy(dx: -3, dy: -3).contains(event.location) else { return }
            work.async { [weak self] in self?.verifyAndQuit(press) }
        default:
            break
        }
    }

    /// Position pre-filter. Close buttons live in a window's top-left corner (top-right in
    /// right-to-left layouts), so a click anywhere else cannot be one and the app is never
    /// asked. The window list comes from the window server, which answers even when the app
    /// under the cursor is hung. Every on-screen window is considered regardless of stacking
    /// order, so a transparent overlay cannot hide a real corner; the cost is an occasional
    /// unnecessary hit-test, never a missed button. If the list is unavailable, fail open.
    private func isNearWindowCorner(_ point: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return true }
        for info in list {
            guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  bounds.width >= 60, bounds.height >= 40
            else { continue }
            let inTop = point.y >= bounds.minY - 2 && point.y <= bounds.minY + cornerHeight
            let inLeft = point.x >= bounds.minX - 2 && point.x <= bounds.minX + cornerWidth
            let inRight = point.x <= bounds.maxX + 2 && point.x >= bounds.maxX - cornerWidth
            if inTop && (inLeft || inRight) { return true }
        }
        return false
    }

    /// One Accessibility hit-test. Returns a value only for an enabled close button that
    /// belongs to an ordinary, non-excluded app.
    private func closeButtonPress(at point: CGPoint) -> PendingClose? {
        configStore.reloadIfChanged()
        let config = configStore.config
        if config.positionPreFilter && !isNearWindowCorner(point) { return nil }

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AX.systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let button = hit,
              AX.string(button, kAXSubroleAttribute as String) == (kAXCloseButtonSubrole as String),
              AX.string(button, kAXRoleAttribute as String) == (kAXButtonRole as String),
              AX.bool(button, kAXEnabledAttribute as String) != false,
              let window = AX.window(of: button),
              let pid = AX.pid(window) ?? AX.pid(button),
              pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular, // skip menu bar / background apps
              let bundleID = app.bundleIdentifier
        else { return nil }

        guard config.allows(bundleID) else { return nil }

        let frame = AX.frame(button) ?? CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
        return PendingClose(
            pid: pid,
            appName: app.localizedName ?? bundleID,
            window: window,
            buttonFrame: frame,
            checkOtherSpaces: config.checkOtherSpaces)
    }

    // MARK: After the click (background queue)

    private func verifyAndQuit(_ press: PendingClose) {
        let start = Date()
        var windowGoneAt: Date?
        var consecutiveEmpty = 0

        while true {
            let elapsed = Date().timeIntervalSince(start)
            let waitingOnDialog = windowGoneAt == nil && elapsed > closeTimeout
            Thread.sleep(forTimeInterval: waitingOnDialog ? 0.4 : 0.08)

            guard let app = NSRunningApplication(processIdentifier: press.pid), !app.isTerminated else {
                return // the app quit by itself
            }
            guard let windows = AX.windows(of: press.pid) else {
                if elapsed > closeTimeout { logLine("\(press.appName): not answering, leaving it alone"); return }
                continue
            }

            if windows.contains(where: { CFEqual($0, press.window) }) {
                // The window is still open.
                if elapsed <= closeTimeout { continue }
                // After the grace period, keep waiting only while a save/confirm prompt is up.
                if hasBlockingPrompt(window: press.window, appWindows: windows), elapsed < dialogTimeout { continue }
                logLine("\(press.appName): window stayed open, not quitting")
                return
            }

            // The window is gone. Is anything real left?
            if windowGoneAt == nil { windowGoneAt = Date() }
            let hereWindows = windows.filter(isRealWindow)
            let elsewhereWindows = press.checkOtherSpaces ? OtherSpaces.offscreenWindows(of: press.pid) : []
            let here = hereWindows.count
            let elsewhere = elsewhereWindows.count

            if here == 0 && elsewhere == 0 {
                consecutiveEmpty += 1
                // Two empty readings in a row, so a window the app opens right after closing
                // (a welcome screen, a restored document) is not missed.
                if consecutiveEmpty >= 2 {
                    logLine("\(press.appName): last window closed, quitting")
                    DispatchQueue.main.async { _ = app.terminate() }
                    return
                }
            } else {
                consecutiveEmpty = 0
                if Date().timeIntervalSince(windowGoneAt!) > lingerAllowance {
                    logLine("\(press.appName): \(here) window(s) here, \(elsewhere) on other Spaces/minimized/hidden, not quitting")
                    for window in hereWindows { logLine("    here: \(describe(window))") }
                    for window in elsewhereWindows { logLine("    elsewhere: \(window)") }
                    return
                }
            }
        }
    }

    /// Windows that should keep an app alive: everything except floating palettes and
    /// tiny helper windows. Minimized windows count.
    private func isRealWindow(_ window: AXUIElement) -> Bool {
        // A window that does not answer in time is assumed real, so a slow app is never quit by mistake.
        guard let role = AX.string(window, kAXRoleAttribute as String) else { return true }
        guard role == (kAXWindowRole as String) else { return false }
        let subrole = AX.string(window, kAXSubroleAttribute as String)
        if subrole == (kAXFloatingWindowSubrole as String) || subrole == (kAXSystemFloatingWindowSubrole as String) {
            return false
        }
        if let frame = AX.frame(window), frame.width < 60 || frame.height < 60 { return false }
        // Overlays and companion panels (e.g. a full-screen transparent canvas for a desktop
        // "pet") are not standard windows and have no close button of their own.
        if subrole != (kAXStandardWindowSubrole as String),
           AX.lacks(window, kAXCloseButtonAttribute as String) {
            return false
        }
        return true
    }

    /// One line about a remaining window, for the log.
    private func describe(_ window: AXUIElement) -> String {
        let title = AX.string(window, kAXTitleAttribute as String) ?? ""
        let subrole = AX.string(window, kAXSubroleAttribute as String) ?? "no subrole"
        let minimized = AX.bool(window, kAXMinimizedAttribute as String) == true ? " minimized" : ""
        let size = AX.frame(window).map { "\(Int($0.width))x\(Int($0.height)) at \(Int($0.minX)),\(Int($0.minY))" } ?? "no frame"
        let closeButton = AX.lacks(window, kAXCloseButtonAttribute as String) ? "no close button" : "has close button"
        return "\"\(title)\" \(subrole)\(minimized) \(size), \(closeButton)"
    }

    /// A sheet on the window, or a separate dialog window, e.g. "Do you want to save…?".
    private func hasBlockingPrompt(window: AXUIElement, appWindows: [AXUIElement]) -> Bool {
        let children = AX.elements(window, kAXChildrenAttribute as String) ?? []
        if children.contains(where: { AX.string($0, kAXRoleAttribute as String) == (kAXSheetRole as String) }) {
            return true
        }
        return appWindows.contains { other in
            guard !CFEqual(other, window) else { return false }
            let subrole = AX.string(other, kAXSubroleAttribute as String)
            return subrole == (kAXDialogSubrole as String) || subrole == (kAXSystemDialogSubrole as String)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configStore = ConfigStore()
    private lazy var watcher = Watcher(configStore: configStore)
    private var statusItem: NSStatusItem?
    private var enabledItem: NSMenuItem?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logLine("LastWindowQuit started (other-Spaces check available: \(OtherSpaces.isAvailable))")
        if configStore.config.showMenuBarIcon { installStatusItem() }

        // Shows the system "grant Accessibility access" prompt the first time.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        startWhenPermitted()
    }

    private func startWhenPermitted() {
        if AXIsProcessTrusted(), watcher.start() {
            logLine("Watching close buttons")
            return
        }
        logLine("Waiting for Accessibility permission (System Settings › Privacy & Security › Device Control and Data Access)")
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted(), self.watcher.start() else { return }
            timer.invalidate()
            self.permissionTimer = nil
            logLine("Watching close buttons")
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "LastWindowQuit") {
            item.button?.image = image
        } else {
            item.button?.title = "✕"
        }
        let menu = NSMenu()
        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = .on
        menu.addItem(enabled)
        menu.addItem(.separator())
        let config = NSMenuItem(title: "Open Settings File", action: #selector(openConfig), keyEquivalent: "")
        config.target = self
        menu.addItem(config)
        let logItem = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LastWindowQuit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        enabledItem = enabled
    }

    @objc private func toggleEnabled() {
        watcher.enabled.toggle()
        enabledItem?.state = watcher.enabled ? .on : .off
        logLine(watcher.enabled ? "Enabled" : "Paused")
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(ConfigStore.url)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(logURL)
    }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
