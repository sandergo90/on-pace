#!/bin/bash
# Render production views with isolated samples, without CLI calls or user preference changes.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/design-verification/source .build/design-verification/output
cp -R UsageNotch/Resources/en.lproj .build/design-verification/
verification_sources=()
for source in UsageNotch/*.swift; do
    if [[ "$source" != UsageNotch/App.swift ]]; then
        verification_source=".build/design-verification/source/${source##*/}"
        cp "$source" "$verification_source"
        verification_sources+=("$verification_source")
    fi
done
# A standalone executable has no application bundle. Use the same source images directly.
python3 - <<'PY'
from pathlib import Path
source = Path('.build/design-verification/source/NotchShape.swift')
code = source.read_text().replace(
    'Image(decorative: provider == .claude ? "ClaudeLogo" : "CodexLogo")',
    'Image(nsImage: NSImage(contentsOfFile: "UsageNotch/Assets.xcassets/\\(provider == .claude ? "ClaudeLogo" : "CodexLogo").imageset/\\(provider == .claude ? "ClaudeLogo" : "CodexLogo").png")!)'
)
source.write_text(code)
PY
# Fixture injection exists only in temporary copies of production sources.
cat >> .build/design-verification/source/UsageStore.swift <<'SWIFT'
extension UsageStore {
    func loadVerificationHistory(_ snapshot: LocalUsageSnapshot) { history = snapshot }
}
SWIFT
cat >> .build/design-verification/source/SettingsView.swift <<'SWIFT'
extension SettingsView {
    static func verification(
        store: UsageStore, tab: Tab, automaticallyChecks: Bool = true, availableVersion: String? = nil
    ) -> Self {
        let updates = UpdateSettings()
        updates.automaticallyChecks = automaticallyChecks
        updates.canCheck = true
        updates.lastCheck = automaticallyChecks ? .now : nil
        let presentation = NotchPresentation()
        presentation.updateVersion = availableVersion
        var view = Self(store: store, updates: updates, presentation: presentation,
                        setAutomaticChecks: { updates.automaticallyChecks = $0 }, checkForUpdates: {},
                        version: "0.1.6")
        view._selectedTab = State(initialValue: tab)
        return view
    }
}
SWIFT
cat >> .build/design-verification/source/LocalUsage.swift <<'SWIFT'
extension LocalUsage {
    init(verificationTokens: Int64, value: Double, days: Int) {
        cacheHitRate = 0.82
        recent = (0..<20).map { Int64(($0 * 7 + 3) % 17) }
        daily = (0..<days).map { index in
            UsageDay(tokens: verificationTokens, sessions: ["session-\(index)"], knownValue: value)
        }
    }
}
SWIFT
xcrun swiftc -swift-version 6 -disable-sandbox -parse-as-library \
    -module-cache-path .build/design-verification/ModuleCache \
    "${verification_sources[@]}" Scripts/VerifyDesign.swift \
    -o .build/design-verification/verify-design
.build/design-verification/verify-design .build/design-verification/output
