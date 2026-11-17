import SwiftUI

/// Auto-close rules. Each one closes a kind of thing after it has gone unused for a while,
/// with a 5-minute heads-up and a "Keep it running" button.
struct AutomateView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sweep up what you've stopped using").font(.headline)
                Text("Slop Cleaner counts time since something was last used, not since it opened. Smart picks a time for each item from how you use it, and gives more time to anything you've wanted back. It never closes anything in use, reserved or being driven, and it warns you 5 minutes before.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                ForEach(AutoCategory.allCases) { cat in AutoRuleRow(category: cat) }
            }

            if !state.pendingAuto.isEmpty {
                SectionTitle("Closing soon", count: state.pendingAuto.count)
                ForEach(state.pendingAuto.sorted { $0.value < $1.value }, id: \.key) { id, due in
                    let t = state.things.first { $0.id == id }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t?.title ?? "Something").font(.callout.weight(.medium))
                            TimelineView(.periodic(from: .now, by: 15)) { _ in
                                Text("In \(Format.duration(max(60, due.timeIntervalSinceNow)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Keep it running") { state.keepRunning(id) }.controlSize(.small)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.1)))
                }
            }

            if !state.autoLog.isEmpty {
                SectionTitle("Recently")
                ForEach(Array(state.autoLog.enumerated()), id: \.offset) { _, e in
                    HStack {
                        Text(e.text).font(.caption)
                        Spacer()
                        Text(e.at.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Text("Apps and system processes are never closed automatically. What Smart learns stays on this Mac.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Forget habits") { state.forgetHabits() }
                    .buttonStyle(.borderless).font(.caption2)
                    .help("Clear what Smart has learned about how you use each item")
            }
        }
    }
}

struct AutoRuleRow: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var state: AppState
    let category: AutoCategory

    var body: some View {
        let hours = prefs.autoLimit(category)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07))
                    Image(systemName: category.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.title).font(.callout.weight(.medium))
                    Text(category.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Toggle("", isOn: Binding(
                    get: { hours != nil },
                    set: { prefs.setAuto(category, hours: $0 ? (hours ?? Automation.smart) : nil) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            if let h = hours {
                HStack {
                    Text("After").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { h }, set: { prefs.setAuto(category, hours: $0) })) {
                        ForEach(AutoCategory.choices, id: \.self) { Text(Automation.hoursText($0)).tag($0) }
                    }
                    .labelsHidden().controlSize(.small).fixedSize()
                    Text(h < 0 ? "picks a time per item" : "unused").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 36)

                // What it would do right now, item by item.
                let current = state.things.filter { AutoCategory.of($0) == category }
                if current.isEmpty {
                    Text("Nothing like this is running right now.")
                        .font(.caption).foregroundStyle(.tertiary).padding(.leading, 36)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(current) { t in
                            if let i = state.insights[t.id] { AutoItemLine(thing: t, insight: i, setting: h) }
                        }
                    }
                    .padding(.leading, 36)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.45)))
    }
}

/// "Pixel 8 API 35 emulator: closes after 1 h unused (idle 20 min so far). Still learning your habits…"
struct AutoItemLine: View {
    let thing: Thing
    let insight: Insight
    let setting: Double

    var body: some View {
        let limit = Automation.limit(setting: setting, insight: insight)
        VStack(alignment: .leading, spacing: 1) {
            Text(thing.title).font(.caption.weight(.medium))
            Group {
                if insight.safety.verdict != .safe || insight.usage.inUseNow {
                    Text("Left alone: \((insight.safety.reasons.first ?? insight.usage.text).lowercasedFirst)")
                } else if let limit {
                    Text("Closes after \(Format.duration(limit)) unused · unused \(Format.duration(insight.usage.idleFor))\(insight.usage.exact ? "" : "+") so far")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if setting < 0, let pick = insight.smart, insight.safety.verdict == .safe {
                Text(pick.reason + ".").font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
