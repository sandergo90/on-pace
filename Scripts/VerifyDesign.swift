import AppKit
import SwiftUI

@main
enum VerifyDesign {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let suite = "be.kodeus.OnPace.DesignVerification.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UsagePreferences(defaults: defaults)
        let store = UsageStore(preferences: preferences)
        let now = Date.now
        func quota(_ id: String, _ title: String, _ used: Double, _ minutes: Int) -> QuotaWindow {
            QuotaWindow(id, title: title, used: used,
                        resetsAt: now.addingTimeInterval(minutes == 300 ? 6_120 : 400_000),
                        durationMinutes: minutes)!
        }
        let session = quota("session", "5-hour session", 99, 300)
        let weekly = quota("week", "Weekly · all models", 4, 10_080)
        let opus = quota("opus", "Weekly · Opus", 0.1, 10_080)
        let monday = Calendar(identifier: .gregorian).nextDate(
            after: now, matching: DateComponents(hour: 6, minute: 0, weekday: 2), matchingPolicy: .nextTime
        )!
        let codexWeek = QuotaWindow("secondary", title: "Weekly limit", used: 5, resetsAt: monday, durationMinutes: 10_080)!
        let claude = UsageReading(windows: [session, weekly, opus], plan: "Max 20×")!
        let codex = UsageReading(windows: [codexWeek], plan: "Pro Lite")!
        store.record(claude, for: .claude)
        store.record(codex, for: .codex)
        let days = (-59...0).map { Calendar.current.date(byAdding: .day, value: $0, to: now)! }
        let snapshot = LocalUsageSnapshot(values: [
            .claude: LocalUsage(verificationTokens: 1_000_000, value: 12, days: 60),
            .codex: LocalUsage(verificationTokens: 200_000, value: 3, days: 60)
        ], days: days, at: now)
        store.loadVerificationHistory(snapshot)

        precondition(claude.compactQuota?.id == session.id)
        precondition(codex.compactQuota?.id == codexWeek.id && codex.detailLimits.isEmpty)
        precondition(claude.detailLimits.map(\.id) == [weekly.id, opus.id])
        precondition(claude.reportedLimitsDescription == "5-hour session and weekly limits")
        precondition(codex.reportedLimitsDescription == "weekly limit")
        for used in [0.0, 0.01, 1, 99, 100] {
            let window = quota("test", "Test", used, 300)
            let compactFill = window.fillWidth(in: 30, minimum: 3)
            let panelFill = window.fillWidth(in: 280, minimum: 4)
            precondition(used == 0 ? compactFill == 0 && panelFill == 0 : compactFill >= 3 && panelFill >= 4)
            precondition(compactFill <= 30 && panelFill <= 280)
        }
        let flatScreen = CompactStyle(topInset: 0, leftArea: nil, rightArea: nil, menuBarHeight: 24)
        guard case .pill = flatScreen else { preconditionFailure("A flat screen should show a pill") }
        let left = CGRect(x: 0, y: 0, width: 600, height: 32)
        let right = CGRect(x: 785, y: 0, width: 600, height: 32)
        let cameraScreen = CompactStyle(topInset: 32, leftArea: left, rightArea: right, menuBarHeight: 33)
        guard case .notch(cameraWidth: 185, height: 33) = cameraScreen else {
            preconditionFailure("The notch should clear the camera and align with the menu bar")
        }
        let hiddenMenuBar = CompactStyle(topInset: 32, leftArea: left, rightArea: right, menuBarHeight: 0)
        precondition(hiddenMenuBar.height == 32, "The notch should cover the camera when the menu bar is hidden")
        for style in [
            CompactStyle(topInset: 34, leftArea: nil, rightArea: nil),
            CompactStyle(topInset: 0, leftArea: left, rightArea: nil),
            CompactStyle(topInset: 0, leftArea: nil, rightArea: right)
        ] {
            guard case .notch = style else { preconditionFailure("A camera indicator should select the notch") }
        }
        let presentation = NotchPresentation()
        presentation.expanded = true
        func panel(_ style: CompactStyle = .previewNotch) -> some View {
            NotchView(store: store, compactStyle: style, detailWidth: NotchShape.expandedWidth,
                      presentation: presentation, togglePin: {}, openSettings: {}, compactWidthChanged: { _ in })
                .frame(width: NotchShape.expandedWidth, height: NotchShape.expandedHeight)
                .background(.black)
        }
        func strip(_ style: CompactStyle, at date: Date = now) -> EdgeLight {
            EdgeLight(store: store, style: style, now: date, animateHighlights: false, action: {})
        }
        func collapsed(_ style: CompactStyle, at date: Date = now) -> some View {
            strip(style, at: date)
                .background(NotchShape(style: style, progress: 0).fill(.black))
                .frame(width: 500, height: 82, alignment: .top)
                .background(Color(red: 0.25, green: 0.30, blue: 0.38))
        }
        try await capture(collapsed(cameraScreen), name: "notch-both", output: output)
        try await capture(collapsed(flatScreen), name: "pill-both", output: output)
        try await capture(panel(), name: "panel-both", output: output)
        try await capture(panel(flatScreen), name: "panel-pill-both", output: output)
        let sonnet = quota("sonnet", "Weekly · Sonnet", 8, 10_080)
        store.record(UsageReading(windows: [session, weekly, opus, sonnet], plan: "Max 20×")!, for: .claude)
        try await capture(panel(), name: "panel-all-claude-limits", output: output)
        try await capture(SettingsView.verification(store: store, tab: .general), name: "settings-general", output: output)
        try await capture(SettingsView.verification(store: store, tab: .providers), name: "settings-providers", output: output)
        preferences.setEnabled(false, for: .claude)
        precondition(UsagePreferences(defaults: defaults).enabledProviders == [.codex])
        preferences.setEnabled(false, for: .codex)
        precondition(preferences.enabledProviders == [.codex])
        precondition(codexWeek.compactReset(at: now)?.text == "Mon 06:00")
        precondition(strip(cameraScreen).accessibilitySummary
            == "AI usage: Codex 5% of weekly limit, resets Monday 06:00. Show details")
        for period in HistoryPeriod.allCases {
            let history = UsageHistory(snapshot: snapshot, period: period, providers: preferences.enabledProviders)
            precondition(Array(history.values.keys) == [.codex])
            precondition(history.rows.count == 2 && history.rows[0].provider == .codex)
            precondition(history.rows.last?.current?.tokens == 200_000 * Int64(period.rawValue))
            precondition(history.rows.last?.current?.apiValue == 3 * Double(period.rawValue))
            precondition(history.rows.last?.incompleteCoverage == false)
        }
        try await capture(collapsed(cameraScreen), name: "notch-codex", output: output)
        try await capture(collapsed(flatScreen), name: "pill-codex", output: output)
        try await capture(panel(), name: "panel-codex", output: output)
        try await capture(SettingsView.verification(store: store, tab: .providers), name: "settings-providers-codex", output: output)
        preferences.setEnabled(true, for: .claude)
        preferences.setEnabled(false, for: .codex)
        precondition(session.compactReset(at: now)?.text == "1h 42m")
        precondition(session.compactReset(at: now.addingTimeInterval(3_600))?.text == "42m")
        precondition(strip(cameraScreen).accessibilitySummary
            == "AI usage: Claude 99% of 5-hour session, resets in 1 hour 42 minutes. Show details")
        try await capture(collapsed(cameraScreen), name: "notch-claude", output: output)
        try await capture(collapsed(flatScreen), name: "pill-claude", output: output)
        try await capture(panel(), name: "panel-claude", output: output)
        try await capture(SettingsView.verification(store: store, tab: .providers), name: "settings-providers-claude", output: output)
        preferences.opensOnHover = false
        precondition(!UsagePreferences(defaults: defaults).opensOnHover)
        preferences.preferredDisplay = "verification-display"
        precondition(UsagePreferences(defaults: defaults).preferredDisplay == "verification-display")
        preferences.preferredDisplay = ""
        try await capture(SettingsView.verification(store: store, tab: .general), name: "settings-click-to-open", output: output)
        print("PASS: layout and quota window selection, reset text and narration, minimum fills, provider persistence, last-provider guard, history filtering and totals")
    }

    @MainActor static func capture<Content: View>(_ content: Content, name: String, output: URL) async throws {
        let host = NSHostingView(rootView: content.preferredColorScheme(.dark))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameOrigin(CGPoint(x: -30_000, y: -30_000))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: output.appendingPathComponent(name + ".png"))
        window.orderOut(nil)
        print("Rendered \(name): \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)")
    }
}
