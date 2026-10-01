import AppKit
import ServiceManagement
import UserNotifications
import Darwin

struct Quota {
    let used: Double
    let minutes: Int
    let reset: Date?
    var remaining: Int { Int((100 - min(100, max(0, used))).rounded()) }
    var expired: Bool { reset.map { $0 <= Date() } ?? false }
    init?(_ object: Any?) {
        guard let d = object as? [String: Any], let u = d["usedPercent"] as? NSNumber,
              let m = d["windowDurationMins"] as? NSNumber, u.doubleValue.isFinite else { return nil }
        used = u.doubleValue; minutes = m.intValue
        reset = (d["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }
}
struct Limits {
    let short: Quota?
    let weekly: Quota?
    init(_ result: [String: Any]) throws {
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        guard let bucket = (buckets?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any]),
              bucket["limitId"] as? String == nil || bucket["limitId"] as? String == "codex" else {
            throw Failure.message("Codex usage is unavailable for this account.")
        }
        let windows = [Quota(bucket["primary"]), Quota(bucket["secondary"])].compactMap { $0 }
        short = windows.first { $0.minutes == 300 }
        weekly = windows.first { $0.minutes == 10080 }
        guard short != nil || weekly != nil else { throw Failure.message("No 5-hour or weekly usage was returned.") }
    }
}
enum Failure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
func codexPath() -> String? {
    let paths = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
    ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
    return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
}
func fetchLimits() throws -> Limits {
    guard let executable = codexPath() else { throw Failure.message("Install Codex or ChatGPT with Codex, then sign in.") }
    let process = Process(), input = Pipe(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["app-server"]
    process.standardInput = input; process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    try process.run()
    let deadline = Date().addingTimeInterval(25)
    defer {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        let grace = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? output.fileHandleForReading.close()
    }
    func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "limitbar", "title": "LimitBar", "version": "1.0.0"]]])
    var buffer = Data()
    while true {
        guard Date() < deadline else { throw Failure.message("Usage refresh timed out. Try Refresh Now.") }
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        let ready = poll(&descriptor, 1, 200)
        if ready == 0 { continue }
        if ready < 0 { if errno == EINTR { continue }; throw Failure.message("Couldn’t read the Codex helper response.") }
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
        guard count >= 0 else { throw Failure.message("Couldn’t read the Codex helper response.") }
        let data = Data(bytes.prefix(count))
        if data.isEmpty { throw Failure.message("Couldn’t read usage. Check your connection and Codex sign-in, then refresh.") }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = message["id"] as? Int {
                if message["error"] != nil { throw Failure.message("Codex couldn’t provide usage. Open Codex and check your sign-in.") }
                if id == 1 {
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2, let result = message["result"] as? [String: Any] {
                    return try Limits(result)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var status: NSStatusItem!
    var limits: Limits?
    var updated: Date?
    var failure: String?
    var loading = false
    var timer: Timer?
    var displayTimer: Timer?
    var resetTimer: Timer?
    let preferences = UserDefaults.standard
    var compact: Bool { preferences.bool(forKey: "compact") }
    var alerts: Bool { preferences.bool(forKey: "alerts") }
    var stale: Bool { limits != nil && (failure != nil || (updated?.timeIntervalSinceNow ?? 0) < -360) }
    var alerted = Set(UserDefaults.standard.stringArray(forKey: "alertedThresholds") ?? [])
    let menu = NSMenu()
    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        status.menu = menu; menu.delegate = self
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
        displayTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.render() }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func value(_ quota: Quota?) -> String {
        guard let quota, !quota.expired else { return "—" }; return "\(quota.remaining)%"
    }
    func render() {
        let warning = failure != nil && limits != nil ? "⚠ " : ""
        let smallest = [limits?.short, limits?.weekly].compactMap { $0 }.filter { !$0.expired }.map { $0.remaining }.min()
        status.button?.image = NSImage(systemSymbolName: stale ? "exclamationmark.triangle" : "gauge.with.dots.needle.50percent", accessibilityDescription: "Codex allowance remaining")
        status.button?.image?.isTemplate = true
        status.button?.imagePosition = .imageLeading
        status.button?.title = compact ? " \(smallest.map { "\($0)%" } ?? "—")" : " \(warning)5h \(value(limits?.short)) · W \(value(limits?.weekly))"
        status.button?.appearsDisabled = stale
        status.button?.toolTip = "Codex usage remaining • 5 hours and weekly" + (failure != nil ? " • Refresh failed" : "")
        rebuildMenu()
    }
    func menuWillOpen(_ menu: NSMenu) { render() }
    func add(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.isEnabled = action != nil; menu.addItem(item); return item
    }
    func quotaView(_ title: String, quota: Quota?) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: 78))
        let heading = NSTextField(labelWithString: title)
        heading.textColor = .labelColor
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.frame = NSRect(x: 18, y: 53, width: 125, height: 18); view.addSubview(heading)
        let amount = NSTextField(labelWithString: "\(value(quota)) remaining")
        amount.alignment = .right; amount.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        amount.frame = NSRect(x: 145, y: 53, width: 147, height: 18); view.addSubview(amount)
        let bar = NSProgressIndicator(frame: NSRect(x: 18, y: 34, width: 274, height: 12))
        bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 100
        let remaining = quota.flatMap { $0.expired ? nil : Double($0.remaining) }
        let color: NSColor = remaining.map { $0 <= 10 ? .systemRed : ($0 <= 20 ? .systemOrange : .systemTeal) } ?? .tertiaryLabelColor
        amount.textColor = .labelColor
        let track = NSView(frame: bar.frame)
        track.wantsLayer = true; track.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor; track.layer?.cornerRadius = 4
        let fill = NSView(frame: NSRect(x: 0, y: 0, width: 274 * (remaining ?? 0) / 100, height: 12))
        fill.wantsLayer = true; fill.layer?.backgroundColor = color.withAlphaComponent(stale ? 0.35 : 1).cgColor; fill.layer?.cornerRadius = 4
        track.addSubview(fill); view.addSubview(track)
        var resetText = "Reset time unavailable"
        if let reset = quota?.reset {
            if reset <= Date() { resetText = "Reset reached · awaiting updated usage" }
            else {
                let seconds = Int(reset.timeIntervalSinceNow)
                let hours = seconds / 3600, minutes = (seconds % 3600) / 60
                let duration = hours >= 24 ? "\(hours / 24)d \(hours % 24)h" : "\(hours)h \(minutes)m"
                let formatter = DateFormatter(); formatter.dateFormat = "EEE h:mm a"
                resetText = "Resets in \(duration) · \(formatter.string(from: reset))"
            }
        }
        let reset = NSTextField(labelWithString: resetText)
        reset.font = .systemFont(ofSize: 11); reset.textColor = .secondaryLabelColor
        reset.frame = NSRect(x: 18, y: 10, width: 280, height: 17); view.addSubview(reset)
        return view
    }
    func rebuildMenu() {
        menu.removeAllItems()
        _ = add("LimitBar · Codex")
        for (name, quota) in [("⚡ 5-hour limit", limits?.short), ("◷ Weekly limit", limits?.weekly)] {
            let item = NSMenuItem(); item.view = quotaView(name, quota: quota); menu.addItem(item)
        }
        menu.addItem(.separator())
        if let failure {
            _ = add(limits == nil ? "Usage unavailable" : "Showing last successful reading")
            let item = add("Connection details…", action: #selector(showError)); item.toolTip = failure
        }
        if let updated {
            let age = max(0, Int(-updated.timeIntervalSinceNow / 60))
            _ = add("\(stale ? "⚠ Stale · " : "")Updated \(age == 0 ? "just now" : "\(age) min ago") · every 3 min")
        }
        let refresh = add(loading ? "Refreshing…" : "Refresh Now", action: #selector(refresh))
        refresh.isEnabled = !loading; refresh.keyEquivalent = "r"
        _ = add("Account & Sign-In…", action: #selector(accountHelp))
        _ = add("Open Codex", action: #selector(openCodex))
        let compactItem = add("Compact Display", action: #selector(toggleCompact)); compactItem.state = compact ? .on : .off
        let alertsItem = add("Low Allowance Alerts", action: #selector(toggleAlerts)); alertsItem.state = alerts ? .on : .off
        if #available(macOS 13.0, *) {
            let login = add("Launch at Login", action: #selector(toggleLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        menu.addItem(.separator())
        let quit = add("Quit LimitBar", action: #selector(quit)); quit.keyEquivalent = "q"
    }
    @objc func refresh() {
        guard !loading else { return }; loading = true; render()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try fetchLimits() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                switch result {
                case .success(let data): self.limits = data; self.updated = Date(); self.failure = nil; self.checkAlerts(data); self.scheduleReset(data)
                case .failure(let error): self.failure = error.localizedDescription
                }
                self.render()
            }
        }
    }
    func scheduleReset(_ data: Limits) {
        resetTimer?.invalidate()
        guard let next = [data.short?.reset, data.weekly?.reset].compactMap({ $0 }).filter({ $0 > Date() }).min() else { return }
        resetTimer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow + 1), repeats: false) { [weak self] _ in self?.refresh() }
    }
    func checkAlerts(_ data: Limits) {
        for (name, quota) in [("5-hour", data.short), ("Weekly", data.weekly)] {
            guard let quota, !quota.expired else { continue }
            let window = "\(name)-\(quota.reset?.timeIntervalSince1970 ?? 0)"
            let crossed = [20, 10, 0].filter { quota.remaining <= $0 }
            guard let threshold = crossed.min() else { continue }
            let key = "\(window)-\(threshold)"
            guard alerts, !alerted.contains(key) else { continue }
            for level in crossed { alerted.insert("\(window)-\(level)") }
            preferences.set(Array(alerted.suffix(100)), forKey: "alertedThresholds")
            let content = UNMutableNotificationContent()
            content.title = quota.remaining == 0 ? "\(name) allowance exhausted" : "\(name) allowance running low"
            content.body = "\(quota.remaining)% remaining. Open LimitBar for the reset time."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
    }
    @objc func toggleCompact() { preferences.set(!compact, forKey: "compact"); render() }
    @objc func toggleAlerts() {
        if alerts { preferences.set(false, forKey: "alerts"); render(); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.preferences.set(granted, forKey: "alerts")
                if !granted {
                    let alert = NSAlert(); alert.messageText = "Notifications are disabled"
                    alert.informativeText = "Allow LimitBar notifications in System Settings → Notifications, then enable alerts again."; alert.runModal()
                }
                self.render()
            }
        }
    }
    @objc func showError() {
        let alert = NSAlert(); alert.messageText = "Couldn’t refresh Codex usage"
        alert.informativeText = failure ?? "Try refreshing again."; alert.runModal()
    }
    @objc func accountHelp() {
        let alert = NSAlert()
        alert.messageText = "Use your own Codex account"
        alert.informativeText = "LimitBar reads usage from the Codex sign-in on this Mac using the official Codex helper. Sign in to Codex with your own ChatGPT account, then choose Refresh Now. LimitBar does not ask for, save, or send your password or access token. To switch accounts, change the active sign-in in Codex first."
        alert.addButton(withTitle: "Open Codex")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn { openCodex() }
    }
    @objc func openCodex() {
        let path = FileManager.default.fileExists(atPath: "/Applications/Codex.app") ? "/Applications/Codex.app" : "/Applications/ChatGPT.app"
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
    @objc func toggleLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } catch {
                let alert = NSAlert(); alert.messageText = "Couldn’t change Launch at Login"
                alert.informativeText = error.localizedDescription; alert.runModal()
            }
            rebuildMenu()
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--self-test") {
    func window(_ used: Double, _ minutes: Int) -> [String: Any] { ["usedPercent": used, "windowDurationMins": minutes] }
    let limits = try Limits(["rateLimitsByLimitId": ["codex": ["primary": window(2, 10080), "secondary": window(9, 300)]]])
    precondition(limits.short?.remaining == 91 && limits.weekly?.remaining == 98)
    precondition(Quota(window(120, 300))?.remaining == 0)
    precondition(Quota(window(-5, 300))?.remaining == 100)
    precondition(Quota(NSNull()) == nil)
    let missing = try Limits(["rateLimits": ["primary": window(30, 300), "secondary": NSNull()]])
    precondition(missing.weekly == nil)
    do { _ = try Limits(["rateLimits": ["primary": window(5, 60)]]); fatalError("Unknown windows accepted") } catch {}
    precondition(Quota(["usedPercent": 5, "windowDurationMins": 300, "resetsAt": 1])!.expired)
    print("PASS: window selection, remaining percentages, clamping, missing windows, unknown windows, expiry")
} else if CommandLine.arguments.contains("--check") {
    do {
        let limits = try fetchLimits()
        print("5-hour remaining: \(limits.short.map { String($0.remaining) } ?? "unavailable")%; weekly remaining: \(limits.weekly.map { String($0.remaining) } ?? "unavailable")%")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate(); app.delegate = delegate
    app.setActivationPolicy(.accessory); app.run()
}
