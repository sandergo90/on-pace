import AppKit
import SwiftUI

extension NSScreen {
    static func usageDisplay(in screens: [NSScreen], preferred: String) -> NSScreen? {
        screens.first { $0.displayIdentifier == preferred } ?? screens.first
    }

    var displayIdentifier: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    var compactStyle: CompactStyle {
        CompactStyle(
            topInset: safeAreaInsets.top, leftArea: auxiliaryTopLeftArea, rightArea: auxiliaryTopRightArea,
            menuBarHeight: frame.maxY - visibleFrame.maxY
        )
    }
}

enum CompactStyle {
    case notch(cameraWidth: CGFloat, height: CGFloat)
    case pill

    private static let previewCameraWidth: CGFloat = 185
    static let previewNotch = Self.notch(cameraWidth: previewCameraWidth, height: 34)
    private static let minimumNotchBodyWidth: CGFloat = 392
    static let notchReadingInset: CGFloat = 16

    init(topInset: CGFloat, leftArea: CGRect?, rightArea: CGRect?, menuBarHeight: CGFloat = 0) {
        guard topInset > 0 || leftArea != nil || rightArea != nil else {
            self = .pill
            return
        }
        let cameraWidth: CGFloat
        if let leftArea, let rightArea, rightArea.minX > leftArea.maxX {
            cameraWidth = rightArea.minX - leftArea.maxX
        } else {
            cameraWidth = Self.previewCameraWidth
        }
        // Keep covering the camera housing when the menu bar is hidden.
        let height = max(menuBarHeight, topInset, leftArea?.height ?? 0, rightArea?.height ?? 0)
        self = .notch(cameraWidth: cameraWidth, height: height > 0 ? height : Self.previewNotch.height)
    }

    var height: CGFloat {
        switch self {
        case .notch(_, let height): height
        case .pill: 30
        }
    }

    var notchWidth: CGFloat? {
        guard case .notch(let cameraWidth, _) = self else { return nil }
        return cameraWidth + 2 * (notchSideWidth(for: cameraWidth) + shoulderWidth)
    }

    func notchSideWidth(for cameraWidth: CGFloat) -> CGFloat {
        // Reserve room for a three-digit percentage and its period beside the camera.
        let readingWidth: CGFloat = 112
        let cameraInset: CGFloat = 4
        return max((Self.minimumNotchBodyWidth - cameraWidth) / 2,
                   Self.notchReadingInset + readingWidth + cameraInset)
    }

    var shoulderWidth: CGFloat {
        switch self {
        case .notch: 12
        case .pill: 10
        }
    }

    var bottomRadius: CGFloat {
        switch self {
        case .notch: 12
        case .pill: 10
        }
    }
}

/// The visible outline is also the AppKit mouse hit region.
struct NotchShape: Shape {
    static let expandedWidth: CGFloat = 712 + 2 * expandedShoulderWidth
    static let expandedHeight: CGFloat = 712
    static let expandedShoulderWidth: CGFloat = 12
    static let shadowSide: CGFloat = 48
    static let shadowBottom: CGFloat = 84
    let style: CompactStyle
    let progress: CGFloat

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0 else { return Path() }
        let bottom = rect.maxY
        let right = rect.maxX
        let s = min(style.shoulderWidth + (Self.expandedShoulderWidth - style.shoulderWidth) * progress, bottom / 2)
        let r = min(style.bottomRadius + (30 - style.bottomRadius) * progress, bottom - s)
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: right, y: 0))
        path.addQuadCurve(to: CGPoint(x: right - s, y: s), control: CGPoint(x: right - s, y: 0))
        path.addLine(to: CGPoint(x: right - s, y: bottom - r))
        path.addQuadCurve(to: CGPoint(x: right - s - r, y: bottom), control: CGPoint(x: right - s, y: bottom))
        path.addLine(to: CGPoint(x: s + r, y: bottom))
        path.addQuadCurve(to: CGPoint(x: s, y: bottom - r), control: CGPoint(x: s, y: bottom))
        path.addLine(to: CGPoint(x: s, y: s))
        path.addQuadCurve(to: .zero, control: CGPoint(x: s, y: 0))
        path.closeSubpath()
        return path
    }
}

struct EdgeLight: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: UsageStore
    let style: CompactStyle
    let now: Date
    var animateHighlights = true
    var action: (() -> Void)? = nil

    private var onlyProvider: Provider? {
        let providers = store.preferences.enabledProviders
        return providers.count == 1 ? providers.first : nil
    }

    private static let logoSize: CGFloat = 14
    private static let barWidth: CGFloat = 30

    var body: some View {
        if let action {
            Button(action: action) {
                contents.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilitySummary)
        } else {
            contents
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
        }
    }

    private var contents: some View {
        Group {
            switch style {
            case .notch(let cameraWidth, _): notchContents(cameraWidth: cameraWidth)
            case .pill: pillContents
            }
        }
        .frame(height: style.height)
    }

    private func notchContents(cameraWidth: CGFloat) -> some View {
        let sideWidth = style.notchSideWidth(for: cameraWidth)
        return HStack(spacing: 0) {
            reading(onlyProvider ?? .claude)
                .padding(.leading, CompactStyle.notchReadingInset)
                .frame(width: sideWidth, alignment: .leading)
            Color.clear.frame(width: cameraWidth)
            Group {
                if let onlyProvider {
                    if let reset = reset(for: onlyProvider) { resetReading(reset, provider: onlyProvider) }
                } else {
                    reading(.codex, mirrored: true)
                }
            }
            .padding(.trailing, CompactStyle.notchReadingInset)
            .frame(width: sideWidth, alignment: .trailing)
        }
        .padding(.horizontal, style.shoulderWidth)
    }

    private var pillContents: some View {
        HStack(spacing: 12) {
            if let onlyProvider {
                reading(onlyProvider)
                if let reset = reset(for: onlyProvider) {
                    divider
                    resetReading(reset, provider: onlyProvider)
                }
            } else {
                let claudeConnected = !store.state(for: .claude).isDisconnected
                let codexConnected = !store.state(for: .codex).isDisconnected
                if claudeConnected { reading(.claude) }
                if claudeConnected && codexConnected { divider }
                if codexConnected { reading(.codex, mirrored: true) }
            }
        }
        .padding(.horizontal, style.shoulderWidth + 12)
        .fixedSize()
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 12)
    }

    private func reading(_ provider: Provider, mirrored: Bool = false) -> some View {
        let state = store.state(for: provider)
        return HStack(spacing: 7) {
            if !state.isDisconnected {
                if !mirrored { ToolSymbol(provider: provider, size: Self.logoSize) }
                if let quota = state.reading?.compactQuota {
                    if mirrored { percentage(quota) }
                    bar(quota, provider: provider, mirrored: mirrored)
                    if !mirrored { percentage(quota) }
                }
                if mirrored { ToolSymbol(provider: provider, size: Self.logoSize) }
            }
        }
        .opacity(stale(provider) ? 0.4 : 1)
    }

    private func reset(for provider: Provider) -> CompactQuotaReset? {
        let state = store.state(for: provider)
        return state.isDisconnected ? nil : state.reading?.compactQuota?.compactReset(at: now)
    }

    private func resetReading(_ reset: CompactQuotaReset, provider: Provider) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.50))
            Text(reset.text)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.90)
        .opacity(stale(provider) ? 0.4 : 1)
        .accessibilityHidden(true)
    }

    private func percentage(_ quota: QuotaWindow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(quota.percentage)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
            if let period = quota.compactPeriod {
                Text(period)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.50))
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
    }

    private func bar(_ quota: QuotaWindow, provider: Provider, mirrored: Bool) -> some View {
        let isStale = stale(provider)
        let reached = quota.level == .reached && (quota.resetsAt.map { $0 > now } ?? true)
        return ZStack(alignment: mirrored ? .trailing : .leading) {
            Capsule().fill(.white.opacity(0.16))
            if quota.fractionUsed > 0 {
                Throb(enabled: reached && !isStale && animateHighlights) {
                    Capsule()
                        .fill(provider.tint)
                        .frame(width: quota.fillWidth(in: Self.barWidth, minimum: 3), height: 4)
                        .shadow(
                            color: provider.tint.opacity(quota.level == .normal || isStale ? 0 : 0.8),
                            radius: reached ? 8 : 5
                        )
                }
            }
        }
        .frame(width: Self.barWidth, height: 4)
        .overlay {
            if animateHighlights && !reduceMotion {
                ResetRipple(provider: provider, mirrored: mirrored, reset: store.compactQuotaResets[provider])
            }
        }
        .accessibilityHidden(true)
    }

    private func stale(_ provider: Provider) -> Bool {
        store.state(for: provider).reading?.isStale(at: now) == true
    }

    var accessibilitySummary: String {
        let connected = store.preferences.enabledProviders.filter { !store.state(for: $0).isDisconnected }
        let descriptions = connected.map { provider in
            guard let quota = store.state(for: provider).reading?.compactQuota else {
                return "\(provider.name) usage unavailable"
            }
            let age = stale(provider) ? ", last known reading" : ""
            let period = quota.durationMinutes == 300 ? "5-hour session" : "weekly limit"
            let reset = onlyProvider == provider ? self.reset(for: provider).map { ", \($0.spoken)" } ?? "" : ""
            return "\(provider.name) \(quota.percentage) of \(period)\(age)\(reset)"
        }
        let readings = descriptions.isEmpty ? "no readings" : descriptions.joined(separator: ", ")
        return "AI usage: \(readings)." + (action == nil ? "" : " Show details")
    }
}

private struct ResetRipple: View {
    let provider: Provider
    let mirrored: Bool
    let reset: Date?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let crest = width * 0.55
            KeyframeAnimator(initialValue: 1.0, trigger: reset) { progress in
                let distance = (width + crest) * (progress - 0.5)
                LinearGradient(colors: [.clear, provider.tint, .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: crest)
                    .offset(x: (width - crest) / 2 + (mirrored ? -distance : distance))
                    .opacity(0.85 * sin(.pi * progress))
            } keyframes: { _ in
                KeyframeTrack(\.self) {
                    MoveKeyframe(0.0)
                    LinearKeyframe(1.0, duration: 0.8)
                }
            }
        }
        .clipShape(Capsule())
        .allowsHitTesting(false)
    }
}

struct Throb<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let enabled: Bool
    var minimum = 0.55
    @ViewBuilder let content: () -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !enabled || reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2) / 3.2
            let fraction = (cos(2 * .pi * phase) + 1) / 2
            content().opacity(enabled && !reduceMotion ? minimum + (1 - minimum) * fraction : 1)
        }
    }
}

struct ToolSymbol: View {
    let provider: Provider
    var size: CGFloat = 14

    var body: some View {
        Image(decorative: provider == .claude ? "ClaudeLogo" : "CodexLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension Provider {
    var tint: Color {
        switch self {
        case .claude: Color(red: 224 / 255, green: 135 / 255, blue: 106 / 255)
        case .codex: Color(red: 127 / 255, green: 168 / 255, blue: 1)
        }
    }
}
