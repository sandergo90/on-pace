import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class UpdateSettings {
    var automaticallyChecks = true
    var canCheck = false
    var lastCheck: Date?
}

struct SettingsView: View {
    enum Tab: String, Hashable {
        case general = "General", providers = "Providers"
    }

    static let size = CGSize(width: 600, height: 500)

    let store: UsageStore
    let updates: UpdateSettings
    let presentation: NotchPresentation
    let setAutomaticChecks: (Bool) -> Void
    let checkForUpdates: () -> Void
    var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    var generalChanged: () -> Void = {}
    var titleChanged: (String) -> Void = { _ in }
    @State private var selectedTab = Tab.general
    @State private var screens = NSScreen.screens
    @State private var now = Date.now

    var body: some View {
        TabView(selection: $selectedTab) {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            providers
                .tabItem { Label("Providers", systemImage: "square.stack") }
                .tag(Tab.providers)
        }
        .padding(12)
        .frame(width: Self.size.width, height: Self.size.height)
        .preferredColorScheme(.dark)
        .onChange(of: selectedTab) { _, tab in titleChanged(tab.rawValue) }
        .onChange(of: store.preferences.opensOnHover) { _, _ in generalChanged() }
        .onChange(of: store.preferences.preferredDisplay) { _, _ in generalChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = .now }
    }

    private var general: some View {
        @Bindable var preferences = store.preferences
        return Form {
            Section {
                Toggle("Open on hover", isOn: $preferences.opensOnHover)
            } header: {
                Text("Panel")
            } footer: {
                Text(preferences.opensOnHover
                     ? "The panel opens when the pointer rests on the usage indicator."
                     : "Click the usage indicator to open the panel.")
            }
            Section {
                Picker("Show on", selection: Binding(
                    get: {
                        screens.contains { $0.displayIdentifier == preferences.preferredDisplay }
                            ? preferences.preferredDisplay : ""
                    },
                    set: { preferences.preferredDisplay = $0 }
                )) {
                    Text("Primary display").tag("")
                    Divider()
                    ForEach(screens, id: \.displayIdentifier) { screen in
                        if let identifier = screen.displayIdentifier {
                            Text(screen.localizedName).tag(identifier)
                        }
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Display")
            } footer: {
                Text("The screen that shows On pace.")
            }
            updateSection
        }
        .formStyle(.grouped)
    }

    private var updateSection: some View {
        let automaticDescription = updates.automaticallyChecks
            ? "Once a day while On pace. runs. Updates never install without asking."
            : "Use Check Now or the gear menu to look for updates."
        let status = presentation.updateVersion.map { "Version \($0) is available" }
            ?? UsageFormat.lastUpdateCheck(updates.lastCheck, now: now)
        return Section("Updates") {
            Toggle(isOn: Binding(get: { updates.automaticallyChecks }, set: { setAutomaticChecks($0) })) {
                updateLabel("Check for updates automatically", description: automaticDescription)
            }
            .toggleStyle(.switch)
            HStack {
                updateLabel(version.map { "On pace. \($0)" } ?? "On pace.", description: status)
                Spacer()
                Button("Check Now", action: checkForUpdates)
                    .buttonStyle(.bordered)
                    .disabled(!updates.canCheck)
                    .accessibilityValue(Text(status))
            }
        }
    }

    private func updateLabel(_ title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(description)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var providers: some View {
        let selectedStyle = NSScreen.usageDisplay(in: screens, preferred: store.preferences.preferredDisplay)?.compactStyle
        let previewStyle: CompactStyle = if let selectedStyle, case .notch = selectedStyle {
            selectedStyle
        } else {
            .previewNotch
        }
        return VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                VStack(spacing: 0) {
                    EdgeLight(store: store, style: previewStyle, now: context.date, animateHighlights: false)
                        .background(NotchShape(style: previewStyle, progress: 0).fill(.black))
                    Spacer(minLength: 0)
                    Text("Preview")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 12)
                        .padding(.bottom, 9)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 76)
                .background(Color(red: 20 / 255, green: 20 / 255, blue: 22 / 255),
                            in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Form {
                Section {
                    ForEach(Provider.allCases) { provider in providerRow(provider) }
                } header: {
                    Text("Show in On pace.")
                } footer: {
                    Text(store.preferences.enabledProviders.count == 1
                         ? "At least one provider has to stay on. With one on, the other side of the notch shows when its limit resets."
                         : "Turned-off providers are hidden from the notch and the panel.")
                }
            }
            .formStyle(.grouped)
        }
    }

    private func providerRow(_ provider: Provider) -> some View {
        let enabled = store.preferences.isEnabled(provider)
        let reported = store.state(for: provider).reading?.reportedLimitsDescription
        let product = provider == .claude ? "Claude Code" : "Codex"
        return HStack(spacing: 10) {
            ToolSymbol(provider: provider, size: 18)
                .frame(width: 28, height: 28)
                .background(provider.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.name).font(.system(size: 13, weight: .semibold))
                Text(enabled ? "\(product) · \(reported ?? "Waiting for usage limits")"
                     : "Off · hidden from the notch and the panel")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(provider.name, isOn: Binding(
                get: { store.preferences.isEnabled(provider) },
                set: { store.preferences.setEnabled($0, for: provider) }
            ))
            .labelsHidden()
            .disabled(enabled && store.preferences.enabledProviders.count == 1)
            .accessibilityHint(enabled && store.preferences.enabledProviders.count == 1
                               ? "At least one provider has to stay on." : "")
        }
        .toggleStyle(.switch)
        .padding(.vertical, 4)
        .opacity(enabled ? 1 : 0.5)
    }
}
