import SwiftUI

struct NotchView: View {
    let store: UsageStore
    let compactStyle: CompactStyle
    let detailWidth: CGFloat
    let presentation: NotchPresentation
    let togglePin: () -> Void
    let openSettings: () -> Void
    let compactWidthChanged: (CGFloat) -> Void

    private var expanded: Bool { presentation.expanded }
    private var pinned: Bool { presentation.pinned }
    private let secondary = Color.white.opacity(0.62)
    private let surface = Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255)

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
                    .frame(width: detailWidth, height: NotchShape.expandedHeight, alignment: .top)
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

            HStack(alignment: .top, spacing: 12) {
                ForEach(store.preferences.enabledProviders) { card($0, at: now) }
            }

            UsageHistoryView(snapshot: store.history, providers: store.preferences.enabledProviders)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, NotchShape.expandedShoulderWidth + 20)
        .padding(.bottom, 18)
    }

    private func card(_ provider: Provider, at now: Date) -> some View {
        let state = store.state(for: provider)
        let reading = state.reading
        let stale = reading?.isStale(at: now) == true
        let activity = store.history?.values[provider]
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
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
                    VStack(alignment: .leading, spacing: 16) {
                        if let quota = reading.compactQuota {
                            headline(quota, provider: provider, stale: stale, now: now)
                        }
                        if !reading.detailLimits.isEmpty {
                            VStack(spacing: 12) {
                                ForEach(reading.detailLimits.prefix(2)) { limit in
                                    quotaRow(limit, provider: provider, pace: stale ? nil : limit.pace(at: now))
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

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 16) {
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

    private func headline(_ quota: QuotaWindow, provider: Provider, stale: Bool, now: Date) -> some View {
        let reached = quota.level == .reached && (quota.resetsAt.map { $0 > now } ?? true)
        let pace = stale ? nil : quota.pace(at: now)
        let projected = pace?.projectedFraction
        let ringSize: CGFloat = 84
        let ringWidth: CGFloat = 8
        return HStack(spacing: 16) {
            ZStack {
                Circle().strokeBorder(.white.opacity(0.09), lineWidth: ringWidth)
                if let projected, projected > quota.fractionUsed {
                    Circle()
                        .trim(from: quota.fractionUsed, to: projected)
                        .stroke(provider.tint.opacity(0.34), style: StrokeStyle(lineWidth: ringWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                        .padding(ringWidth / 2)
                }
                if quota.fractionUsed > 0 {
                    Throb(enabled: reached && !stale && expanded) {
                        Circle()
                            .trim(from: 0, to: quota.fractionUsed)
                            .stroke(provider.tint, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(ringWidth / 2)
                            .shadow(
                                color: provider.tint.opacity(quota.level == .normal || stale ? 0 : 0.60),
                                radius: reached ? 10 : 7
                            )
                    }
                }
                if let projected, projected < 1, projected > quota.fractionUsed {
                    Capsule()
                        .fill(.white.opacity(0.92))
                        .frame(width: 2.25, height: ringWidth + 6)
                        .offset(y: -(ringSize - ringWidth) / 2)
                        .frame(width: ringSize, height: ringSize)
                        .rotationEffect(.degrees(360 * projected))
                }
                Text(quota.percentage).font(.system(size: 22, weight: .bold))
            }
            .frame(width: ringSize, height: ringSize)

            VStack(alignment: .leading, spacing: 6) {
                Text(quota.durationMinutes == 300 ? "5-hour session" : "Weekly limit").font(.system(size: 11.5)).foregroundStyle(secondary)
                if quota.durationMinutes != 300, let reset = quota.resetsAt {
                    Text("Resets \(UsageFormat.weekday(reset)) \(UsageFormat.time(reset))")
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else if let minutes = quota.minutesUntilReset(from: now) {
                    Text(minutes == 0 ? "Reset pending" :
                         "\(quota.level == .reached ? "Back in" : "Resets in") \(UsageFormat.duration(minutes))")
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                if let pace {
                    let emphasis = pace.isEmphasized
                    let ink = emphasis ? provider.tint : .white.opacity(0.75)
                    HStack(spacing: 5) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .accessibilityHidden(true)
                        Text(pace.title)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .foregroundStyle(ink)
                    .padding(.leading, 7)
                    .padding(.trailing, 9)
                    .padding(.vertical, 3)
                    .background(emphasis ? provider.tint.opacity(0.16) : .white.opacity(0.07), in: Capsule())
                } else if quota.durationMinutes != 300 {
                    Text("No 5-hour window reported")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: ringSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.name) \(quota.durationMinutes == 300 ? "5-hour session" : "weekly limit") \(quota.percentage) used\(pace?.accessibilitySuffix ?? "")")
        .accessibilityValue(quota.resetsAt.map { "Resets \(UsageFormat.weekday($0)) \(UsageFormat.time($0))" } ?? "")
    }

    private func quotaRow(_ quota: QuotaWindow, provider: Provider, pace: QuotaPace?) -> some View {
        VStack(spacing: 6) {
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
            GeometryReader { geometry in
                let fillWidth = quota.fillWidth(in: geometry.size.width, minimum: 4)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3).fill(provider.tint)
                        .frame(width: fillWidth)
                }
                .overlay {
                    if let projected = pace?.projectedFraction {
                        QuotaForecastBar(projected: projected, fillWidth: fillWidth, tint: provider.tint.opacity(0.34),
                                         tickSize: CGSize(width: 2, height: 10))
                    }
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
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
