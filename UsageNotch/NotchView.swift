import SwiftUI

struct NotchView: View {
    let store: UsageStore
    let compactStyle: CompactStyle
    let detailSize: CGSize
    let presentation: NotchPresentation
    let togglePin: () -> Void
    let openDashboard: () -> Void
    let openSettings: () -> Void
    let compactWidthChanged: (CGFloat) -> Void
    let expandedHeightChanged: (CGFloat) -> Void
    @State private var dashboardHeight: CGFloat?

    private var expanded: Bool { presentation.expanded }
    private var pinned: Bool { presentation.pinned }
    private let secondary = Color.white.opacity(0.62)

    var body: some View {
        TimelineView(.periodic(from: .now, by: expanded ? 1 : 5)) { timeline in
            ZStack(alignment: .top) {
                compact(at: timeline.date)
                    .opacity(expanded ? 0 : 1)
                    .animation(presentation.animates ? .easeOut(duration: 0.13).delay(expanded ? 0 : 0.07) : nil,
                               value: expanded)
                    .allowsHitTesting(!expanded)
                    .accessibilityHidden(expanded)

                details(at: timeline.date)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: expandedHeightChanged)
                    .frame(width: detailSize.width, height: detailSize.height, alignment: .top)
                    .offset(y: expanded ? 0 : 8)
                    .opacity(expanded ? 1 : 0)
                    .animation(presentation.animates ? .easeOut(duration: expanded ? 0.19 : 0.11)
                        .delay(expanded ? 0.075 : 0) : nil, value: expanded)
                    .allowsHitTesting(expanded)
                    .accessibilityHidden(!expanded)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .monospacedDigit()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func compact(at now: Date) -> some View {
        EdgeLight(store: store, style: compactStyle, now: now, animateHighlights: !expanded, action: togglePin)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: compactWidthChanged)
            .opacity(presentation.showsLaunchMark ? 0 : 1)
            .overlay(alignment: .leading) {
                if presentation.showsLaunchMark {
                    TrailMark(size: 32, animateOnAppear: true)
                        .padding(.leading, compactStyle.shoulderWidth + 16)
                        .allowsHitTesting(false)
                }
            }
    }

    private func details(at now: Date) -> some View {
        let updateAvailable = presentation.updateVersion != nil
        return VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button(action: togglePin) {
                    HStack(spacing: 7) {
                        TrailMark(size: 22)
                        OnPaceWordmark(size: 14)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("On pace.")
                .accessibilityHint(pinned ? "Unpins the usage panel" : "Keeps the usage panel open")
                Spacer(minLength: 0)
                Text(syncStatus(at: now))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                control("arrow.clockwise", label: "Refresh usage", action: store.refresh)
                    .disabled(store.isRefreshing)
                control("arrow.up.left.and.arrow.down.right", label: String(localized: "dashboard.open"), action: openDashboard)
                control("gearshape", label: updateAvailable ? "Settings, update available" : "Settings", action: openSettings)
                    .overlay(alignment: .topTrailing) {
                        if updateAvailable {
                            Circle()
                                .fill(TrailMark.lime)
                                .frame(width: 5, height: 5)
                                .padding(2)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                control(pinned ? "pin.fill" : "pin", label: "Pin usage panel", selected: pinned, action: togglePin)
                    .accessibilityValue(pinned ? "On" : "Off")
                    .accessibilityAddTraits(pinned ? .isSelected : [])
            }
            .foregroundStyle(secondary)
            .padding(.horizontal, 4)
            .frame(height: 34)

            ScrollView {
                UsageDashboard(store: store, now: now, animateHighlights: expanded)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { dashboardHeight = $0 }
            }
            .frame(maxHeight: dashboardHeight)
        }
        .padding(.horizontal, NotchShape.expandedShoulderWidth + 20)
        .padding(.bottom, 18)
    }

    private func control(_ icon: String, label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.77))
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func syncStatus(at now: Date) -> String {
        if store.isRefreshing { return "Syncing…" }
        guard let updated = store.lastUpdated ?? store.history?.at else { return "Waiting for data" }
        let elapsed = Int(max(0, now.timeIntervalSince(updated)))
        if elapsed < 60 { return "Synced \(elapsed)s ago" }
        if elapsed < 3600 { return "Synced \(elapsed / 60)m ago" }
        return "Synced at \(UsageFormat.time(updated))"
    }
}

struct UsageDashboard: View {
    let store: UsageStore
    let now: Date
    var animateHighlights = false
    private let secondary = Color.white.opacity(0.62)
    private let surface = Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255)

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(store.preferences.enabledProviders) { card($0) }
            }
            UsageHistoryView(snapshot: store.history, providers: store.preferences.enabledProviders)
                .fixedSize(horizontal: false, vertical: true)
        }
        .monospacedDigit()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func card(_ provider: Provider) -> some View {
        let state = store.state(for: provider)
        let reading = state.reading
        let stale = reading?.isStale(at: now) == true
        let activity = store.history?.values[provider]
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    ToolSymbol(provider: provider)
                        .frame(width: 26, height: 26)
                        .background(provider.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                    Text(provider.name)
                        .font(.system(size: 15, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    if let plan = reading?.plan {
                        Text(provider == .codex ? "ChatGPT \(plan)" : plan)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .overlay { Capsule().strokeBorder(.white.opacity(0.14)) }
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    Spacer(minLength: 0)
                    if let today = activity?.today, let value = today.apiValue {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(UsageFormat.euro(value))
                                .font(.system(size: 13, weight: .semibold))
                            Text(today.hasUnpricedUsage ? "Partial API value today" : "API value today")
                                .font(.system(size: 10))
                                .foregroundStyle(secondary)
                        }
                        .lineLimit(1)
                        .help("Estimated value of local tokens at standard API rates, converted to euros")
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(height: 32)

                if let reading {
                    VStack(alignment: .leading, spacing: 12) {
                        if let quota = reading.compactQuota {
                            headline(quota, provider: provider, sampledAt: reading.fetchedAt, stale: stale)
                        }
                        if !reading.detailLimits.isEmpty {
                            VStack(spacing: 10) {
                                ForEach(reading.detailLimits) { limit in
                                    quotaRow(limit, provider: provider, sampledAt: reading.fetchedAt, stale: stale)
                                }
                            }
                        }
                    }
                    .opacity(stale ? 0.4 : 1)
                    .accessibilityHint(stale ? "Last known quota" : "")
                } else if case .unavailable(let reason, _) = state {
                    Text(reason.message(for: provider)).font(.system(size: 12)).foregroundStyle(secondary)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 12) {
                ActivityChart(usage: activity, measuredAt: store.history?.at, tint: provider.tint)
                if let activity {
                    HStack(spacing: 8) {
                        metric("Tokens today", value: activity.today.tokens.formatted(.number.notation(.compactName).locale(UsageFormat.locale)),
                               help: "\(activity.today.tokens.formatted()) tokens, including cache")
                        metric("Sessions", value: activity.today.sessions.count.formatted(), help: "Local sessions with token usage today")
                        metric("Cache hits", value: activity.cacheHitRate?.formatted(.percent.precision(.fractionLength(0))) ?? "N/A",
                               help: "Share of input tokens served from cache")
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.07)).allowsHitTesting(false) }
    }

    private func headline(_ quota: QuotaWindow, provider: Provider, sampledAt: Date, stale: Bool) -> some View {
        let highlights = !stale && (quota.resetsAt.map { $0 > now } ?? true)
        let marker = stale ? nil : quota.elapsedFraction(at: now)
        let forecast = stale ? nil : quota.pace(sampledAt: sampledAt, now: now)
        let reset = quota.compactReset(at: now)?.spoken
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota.durationMinutes == 300 ? "5-hour session" : "Weekly limit")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Text(quota.percentage).font(.system(size: 22, weight: .bold))
            }
            QuotaBar(quota: quota, tint: provider.tint, pace: marker, highlights: highlights, animates: animateHighlights)
                .frame(height: 8)

            HStack(spacing: 8) {
                if quota.durationMinutes != 300, let reset = quota.resetsAt {
                    Text("Resets \(UsageFormat.weekday(reset)) \(UsageFormat.time(reset))")
                } else if let minutes = quota.minutesUntilReset(from: now) {
                    Text(minutes == 0 ? "Reset pending" :
                         "\(quota.level == .reached ? "Back in" : "Resets in") \(UsageFormat.duration(minutes))")
                }
                Spacer(minLength: 0)
                if let forecast { forecastText(forecast) }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.name) \(quota.durationMinutes == 300 ? "5-hour session" : "weekly limit") \(quota.percentage) used")
        .accessibilityValue([reset, marker.map(UsageFormat.paceMarker), forecast?.title(at: now)]
            .compactMap { $0 }.joined(separator: ", "))
    }

    private func quotaRow(_ quota: QuotaWindow, provider: Provider, sampledAt: Date, stale: Bool) -> some View {
        let marker = stale ? nil : quota.elapsedFraction(at: now)
        let forecast = stale ? nil : quota.pace(sampledAt: sampledAt, now: now)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(quota.title).foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 3)
                Text(quota.percentage).fontWeight(.semibold)
                if let reset = quota.resetsAt {
                    Text("· resets \(UsageFormat.weekday(reset)) \(UsageFormat.time(reset))")
                        .foregroundStyle(secondary)
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .minimumScaleFactor(0.83)
            HStack(spacing: 9) {
                QuotaBar(quota: quota, tint: provider.tint, pace: marker)
                    .frame(height: 6)
                if let forecast {
                    forecastText(forecast)
                        .frame(width: 115, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(marker.map(UsageFormat.paceMarker) ?? "")
    }

    private func forecastText(_ forecast: QuotaPace) -> some View {
        Text(forecast.title(at: now))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .help(String(localized: "pace.explanation"))
    }

    private func metric(_ label: String, value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(secondary)
            Text(value).font(.system(size: 14, weight: .semibold))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .help(help)
        .accessibilityElement(children: .combine)
    }
}
