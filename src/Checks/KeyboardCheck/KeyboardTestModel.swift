import AppKit
import ApplicationServices
import Combine
import CoreGraphics

/// Keyboard test state.
/// - Local monitor: lights keys inside this window.
/// - Kiosk presentationOptions: system hotkeys (Cmd+Tab / Spotlight / Force Quit).
/// - HID CGEventTap: third-party global hotkeys (e.g. F1 screenshot tools).
///   Primary TCC: **Accessibility**.
@MainActor
final class KeyboardTestModel: ObservableObject {
    @Published private(set) var testedKeyCodes: Set<UInt16> = []
    @Published private(set) var pressedKeyCodes: Set<UInt16> = []
    @Published private(set) var stuckKeyCodes: Set<UInt16> = []
    /// HID tap is live — third-party global hotkeys are swallowed.
    @Published private(set) var globalHotkeyBlockingActive = false
    /// Show the permission banner (usually Accessibility).
    @Published private(set) var needsHotkeyPermission = false
    /// L10n key for the banner body (`check.keyboard.a11y` / `a11y_relaunch`).
    @Published private(set) var hotkeyPermissionMessageKey = "check.keyboard.a11y"

    /// Backward-compatible alias used by the view.
    var needsAccessibilityPermission: Bool { needsHotkeyPermission }

    private var pressStartTimes: [UInt16: Date] = [:]
    private var monitor: Any?
    private var stuckCheckTimer: Timer?
    private var savedPresentationOptions: NSApplication.PresentationOptions?
    private var activationObservers: [NSObjectProtocol] = []
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    /// True only while the fullscreen keyboard session should own taps / kiosk mode.
    private var isSessionActive = false
    /// Skip tap teardown while jumping to System Settings (otherwise Recheck looks "broken").
    private var suppressResignTeardown = false
    private static var didRequestAccessibilityPrompt = false

    /// Allowed combo: hideDock / hideMenuBar + disable* flags.
    /// hideDock also kills the Spotlight menu; disableProcessSwitching kills Cmd+Tab / Exposé.
    private static let kioskOptions: NSApplication.PresentationOptions = [
        .hideDock,
        .hideMenuBar,
        .disableProcessSwitching,
        .disableForceQuit,
        .disableSessionTermination,
        .disableHideApplication,
    ]

    let totalKeyCount: Int
    var onRequestFinish: (() -> Void)?

    private static let escKeyCode: UInt16 = 53
    private static let escHoldToExitSeconds: TimeInterval = 1.2
    private static let stuckThresholdSeconds: TimeInterval = 5.0

    init(totalKeyCount: Int = KeyboardLayout.totalKeyCount) {
        self.totalKeyCount = totalKeyCount
    }

    var progress: Double {
        totalKeyCount == 0 ? 0 : Double(testedKeyCodes.count) / Double(totalKeyCount)
    }

    var isComplete: Bool { testedKeyCodes.count >= totalKeyCount }

    func start() {
        guard !isSessionActive else { return }
        isSessionActive = true
        activateKioskMode()

        // Swallow all keys including Command chords (Cmd+Q / Cmd+W / Cmd+H).
        // Cmd+Tab, Spotlight, Cmd+Opt+Esc are blocked by kiosk presentationOptions.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .systemDefined]
        ) { [weak self] event in
            guard let self, self.isSessionActive else { return event }
            switch event.type {
            case .keyDown, .keyUp, .flagsChanged:
                self.handle(event)
            default:
                break // media keys: swallow only
            }
            return nil
        }
        stuckCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForStuckKeys() }
        }

        // System-level tap so F1 etc. are not delivered to other apps first.
        installGlobalEventTap()
    }

    /// Release local monitor, CGEventTap, and kiosk options. Idempotent — call on every exit path.
    func stop() {
        isSessionActive = false
        suppressResignTeardown = false
        stopGlobalEventTap()
        needsHotkeyPermission = false
        globalHotkeyBlockingActive = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        stuckCheckTimer?.invalidate()
        stuckCheckTimer = nil
        deactivateKioskMode()
    }

    // MARK: - Suppress system hotkeys

    private func activateKioskMode() {
        if savedPresentationOptions == nil {
            savedPresentationOptions = NSApp.presentationOptions
        }
        NSApp.presentationOptions = Self.kioskOptions

        guard activationObservers.isEmpty else { return }
        let center = NotificationCenter.default
        activationObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isSessionActive else { return }
                // Opening System Settings: keep tap/session (Recheck must still work).
                if self.suppressResignTeardown { return }
                // Fullscreen toggle briefly resigns while we stay frontmost — don't tear down
                // or Accessibility looks "broken" and hotkeys flicker.
                if let front = NSWorkspace.shared.frontmostApplication,
                   front.bundleIdentifier == Bundle.main.bundleIdentifier {
                    return
                }
                self.stopGlobalEventTap()
                self.restorePresentationOptions()
            }
        })
        activationObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isSessionActive else { return }
                self.suppressResignTeardown = false
                NSApp.presentationOptions = Self.kioskOptions
                // Brief delay so TCC reflects a grant made in System Settings.
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard self.isSessionActive else { return }
                self.installGlobalEventTap()
            }
        })
    }

    private func deactivateKioskMode() {
        restorePresentationOptions()
        activationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        activationObservers.removeAll()
        savedPresentationOptions = nil
    }

    private func restorePresentationOptions() {
        guard let saved = savedPresentationOptions else { return }
        NSApp.presentationOptions = saved
    }

    // MARK: - Global key interception (CGEventTap)

    /// After granting Accessibility, or when tapping Recheck.
    func retryGlobalHotkeyBlocking() {
        guard isSessionActive else { return }
        stopGlobalEventTap()
        requestAccessibilityPromptIfNeeded(force: true)
        installGlobalEventTap()
        refreshPermissionBanner(hidTapInstalled: eventTap != nil)
    }

    func openAccessibilitySettings() {
        suppressResignTeardown = true
        openPrivacyPane(legacy: "Privacy_Accessibility",
                        modern: "com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
    }

    private func openPrivacyPane(legacy: String, modern: String) {
        let candidates = [
            "x-apple.systempreferences:\(modern)",
            "x-apple.systempreferences:com.apple.preference.security?\(legacy)",
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    private func requestAccessibilityPromptIfNeeded(force: Bool) {
        if !force && Self.didRequestAccessibilityPrompt { return }
        if force && AXIsProcessTrusted() { return }
        Self.didRequestAccessibilityPrompt = true
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func installGlobalEventTap() {
        guard isSessionActive else { return }
        if eventTap != nil {
            refreshPermissionBanner(hidTapInstalled: true)
            return
        }

        requestAccessibilityPromptIfNeeded(force: false)

        var mask: CGEventMask = 0
        mask |= CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
        mask |= CGEventMask(1) << CGEventMask(CGEventType.keyUp.rawValue)
        mask |= CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue)
        mask |= CGEventMask(1) << 14 // NX_SYSDEFINED (media keys)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        func makeTap(at location: CGEventTapLocation) -> CFMachPort? {
            CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: keyboardEventTapCallback,
                userInfo: refcon
            )
        }

        // Only HID taps beat other apps' global hotkeys. Session taps are insufficient —
        // do not fall back and pretend blocking is on.
        guard let tap = makeTap(at: .cghidEventTap) else {
            refreshPermissionBanner(hidTapInstalled: false)
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
        refreshPermissionBanner(hidTapInstalled: true)
    }

    private func refreshPermissionBanner(hidTapInstalled: Bool) {
        globalHotkeyBlockingActive = hidTapInstalled
        guard isSessionActive else {
            needsHotkeyPermission = false
            return
        }
        if hidTapInstalled {
            needsHotkeyPermission = false
            return
        }
        needsHotkeyPermission = true
        hotkeyPermissionMessageKey = AXIsProcessTrusted()
            ? "check.keyboard.a11y_relaunch"
            : "check.keyboard.a11y"
    }

    private func stopGlobalEventTap() {
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        eventTapSource = nil
        eventTap = nil
        globalHotkeyBlockingActive = false
    }
    /// System disabled the tap (timeout / user input) — re-enable.
    fileprivate func reenableEventTap() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    fileprivate func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown: handle(kind: .down, keyCode: event.keyCode)
        case .keyUp: handle(kind: .up, keyCode: event.keyCode)
        case .flagsChanged: handle(kind: .flagsChanged, keyCode: event.keyCode)
        default: break
        }
    }

    /// Shared entry for local monitor + CGEventTap; pass raw keycodes only (no CGEvent/NSEvent across isolation).
    fileprivate func handle(kind: KeyboardEventKind, keyCode code: UInt16) {
        switch kind {
        case .down:
            pressedKeyCodes.insert(code)
            testedKeyCodes.insert(code)
            if pressStartTimes[code] == nil {
                pressStartTimes[code] = Date()
            }
            stuckKeyCodes.remove(code)

        case .up:
            if code == Self.escKeyCode, let start = pressStartTimes[code] {
                let held = Date().timeIntervalSince(start)
                if held >= Self.escHoldToExitSeconds {
                    onRequestFinish?()
                }
            }
            pressedKeyCodes.remove(code)
            pressStartTimes[code] = nil
            stuckKeyCodes.remove(code)

        case .flagsChanged:
            // Modifiers lack clean down/up pairs — toggle on "already down".
            testedKeyCodes.insert(code)
            if pressedKeyCodes.contains(code) {
                pressedKeyCodes.remove(code)
                pressStartTimes[code] = nil
            } else {
                pressedKeyCodes.insert(code)
                pressStartTimes[code] = Date()
            }
            stuckKeyCodes.remove(code)
        }
    }

    private func checkForStuckKeys() {
        let now = Date()
        for (code, start) in pressStartTimes where now.timeIntervalSince(start) > Self.stuckThresholdSeconds {
            stuckKeyCodes.insert(code)
        }
    }

    /// Result: all keys + no stuck → pass; stuck → warning; early exit → grade by coverage.
    func buildResult() -> CheckResult {
        var details: [String: String] = [
            "tested": "\(testedKeyCodes.count) / \(totalKeyCount)",
        ]
        if !stuckKeyCodes.isEmpty {
            let names = stuckKeyCodes.compactMap { code in
                KeyboardLayout.allKeys.first { $0.keyCode == code }?.label
            }.joined(separator: ", ")
            details["stuck"] = names
            return CheckResult(
                id: "keyboard",
                title: L10n.t("check.keyboard.title"),
                status: .warning,
                summary: L10n.t("check.keyboard.result.stuck", names),
                rawDetails: RawDetails.localize(details, using: [
                    "tested": "check.keyboard.detail.tested",
                    "stuck": "check.keyboard.detail.stuck",
                ])
            )
        }
        let localized = RawDetails.localize(details, using: [
            "tested": "check.keyboard.detail.tested",
            "stuck": "check.keyboard.detail.stuck",
        ])
        if isComplete {
            return CheckResult(
                id: "keyboard",
                title: L10n.t("check.keyboard.title"),
                status: .pass,
                summary: L10n.t("check.keyboard.result.ok", totalKeyCount),
                rawDetails: localized
            )
        }
        return CheckResult(
            id: "keyboard",
            title: L10n.t("check.keyboard.title"),
            status: .warning,
            summary: L10n.t("check.keyboard.result.partial", testedKeyCodes.count, totalKeyCount),
            rawDetails: localized
        )
    }
}

/// CGEventTap C callback — intercept before other apps (incl. F1 global hotkeys) see the key.
private func keyboardEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let model = Unmanaged<KeyboardTestModel>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { model.reenableEventTap() }
        return Unmanaged.passUnretained(event)
    }

    let kind: KeyboardEventKind?
    switch type {
    case .keyDown: kind = .down
    case .keyUp: kind = .up
    case .flagsChanged: kind = .flagsChanged
    default: kind = nil
    }
    if let kind {
        let rawKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if let keyCode = UInt16(exactly: rawKeyCode) {
            MainActor.assumeIsolated {
                model.handle(kind: kind, keyCode: keyCode)
            }
        }
    }
    // Swallow all keys (incl. NX_SYSDEFINED media) so third-party global hotkeys don't fire.
    return nil
}

fileprivate enum KeyboardEventKind {
    case down, up, flagsChanged
}
