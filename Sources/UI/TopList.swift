import AppKit
import SwiftUI

struct TopList: View {
    @EnvironmentObject var state: AppState
    @State private var byMemory = false
    @State private var showAll = false

    var body: some View {
        let query = state.uiQuery
        let filtered = state.things.filter { t in
            query.isEmpty || t.listenPorts.contains { String($0) == query } || t.title.localizedCaseInsensitiveContains(query) || t.subtitle.localizedCaseInsensitiveContains(query)
                || t.processes.contains { $0.name.localizedCaseInsensitiveContains(query) || String($0.pid) == query }
        }
        let sorted = byMemory ? filtered.sorted { $0.memory > $1.memory } : filtered
        let list = Array(sorted.prefix(showAll || !query.isEmpty ? 40 : 10))
        let maxValue = byMemory ? Double(list.first?.memory ?? 1) : max(100, list.first?.cpu ?? 100)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("Running now")
                Picker("", selection: $byMemory) {
                    Text("CPU").tag(false)
                    Text("Memory").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find an app, process, port or pid", text: $state.uiQuery)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { state.uiQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(0.6)))

            if state.things.isEmpty {
                Text("Measuring…").font(.caption).foregroundStyle(.secondary)
            } else if list.isEmpty {
                Text("Nothing matches “\(query)”.").font(.caption).foregroundStyle(.secondary)
            }

            VStack(spacing: 2) {
                ForEach(list) { t in
                    ThingRow(thing: t, insight: state.insights[t.id], byMemory: byMemory,
                             fraction: byMemory ? Double(t.memory) / max(1, maxValue) : t.cpu / maxValue,
                             series: state.thingSeries[t.id] ?? [],
                             expanded: state.uiExpanded.contains(t.id)) {
                        if state.uiExpanded.contains(t.id) { state.uiExpanded.remove(t.id) } else { state.uiExpanded.insert(t.id) }
                    }
                }
            }

            if query.isEmpty && sorted.count > 10 {
                Button(showAll ? "Show fewer" : "Show all \(min(sorted.count, 40))") { showAll.toggle() }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
    }
}

struct ThingRow: View {
    @EnvironmentObject var state: AppState
    let thing: Thing
    let insight: Insight?
    let byMemory: Bool
    let fraction: Double
    let series: [Double]
    let expanded: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    ThingIcon(thing: thing).frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(thing.title).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(byMemory ? Format.bytes(thing.memory) : Format.cores(thing.cpu))
                                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            UsageLine(thing: thing, usage: insight?.usage)
                            Spacer(minLength: 4)
                            if !byMemory && series.count > 2 {
                                Sparkline(values: series, maxValue: 100, color: .secondary)
                                    .frame(width: 46, height: 12)
                            }
                        }
                        Bar(fraction: fraction)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ThingDetail(thing: thing, insight: insight, byMemory: byMemory)
                    .padding(.leading, 34)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(expanded ? Color.primary.opacity(0.04) : hover ? Color.primary.opacity(0.05) : .clear))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: expanded)
    }
}

/// "in web/client · In use by MyApp in QA iPhone", with a green dot when in use now.
struct UsageLine: View {
    let thing: Thing
    let usage: Usage?

    var body: some View {
        HStack(spacing: 4) {
            if let u = usage, u.inUseNow {
                Circle().fill(Color.green).frame(width: 6, height: 6)
            }
            Text([thing.subtitle, usage?.text].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .help(usage?.text ?? thing.subtitle)
    }
}

/// Expanded row: what it is, why it is or isn't safe to quit, what quitting does, and the button.
struct ThingDetail: View {
    @EnvironmentObject var state: AppState
    let thing: Thing
    let insight: Insight?
    let byMemory: Bool
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(thing.kind.label) · up \(Format.duration(Date().timeIntervalSince(thing.startedAt))) · \(Format.bytes(thing.memory))")
                if let u = insight?.usage {
                    Text(u.text + (u.exact || u.inUseNow ? "" : " (Slop Cleaner can only vouch for the time it has been watching)"))
                }
            }
            .font(.caption).foregroundStyle(.secondary)

            if let s = insight?.safety {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(s.reasons, id: \.self) { r in
                        Label(r, systemImage: s.verdict == .blocked ? "hand.raised.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(s.verdict == .blocked ? Color.red : Color.orange)
                    }
                    if s.verdict == .safe {
                        Label("Nothing is using it right now.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    ForEach(s.notes, id: \.self) { n in
                        Label(n, systemImage: "info.circle").foregroundStyle(.secondary)
                    }
                    if !s.effect.isEmpty {
                        Label(s.effect, systemImage: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
                    }
                    if AutoCategory.of(thing) != nil, let pick = insight?.smart {
                        Label("Smart close-after time: \(Format.duration(pick.seconds)) unused. \(pick.reason).",
                              systemImage: "wand.and.stars").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .labelStyle(TightLabel())

                actionRow(s)
                if let url = ClaudeLinks.url(for: thing) {
                    Button("Open in Claude") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.borderless).font(.caption)
                }
            }

            DisclosureGroup("Processes (\(thing.processes.count))") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(thing.processes.sorted { byMemory ? $0.memory > $1.memory : $0.cpu > $1.cpu }.prefix(8), id: \.key) { p in
                        HStack {
                            Text(p.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("pid \(p.pid)").foregroundStyle(.tertiary)
                            Text(byMemory ? Format.bytes(p.memory) : String(format: "%.0f%%", p.cpu))
                                .frame(width: 58, alignment: .trailing)
                        }
                        .font(.caption.monospacedDigit())
                    }
                    if thing.processes.count > 8 {
                        Text("+ \(thing.processes.count - 8) more").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    @ViewBuilder private func actionRow(_ s: Safety) -> some View {
        HStack(spacing: 8) {
            if state.isRunning(thing) {
                ProgressView().controlSize(.small)
                Text("Checking it's still safe, then stopping…").font(.caption).foregroundStyle(.secondary)
            } else if s.verdict != .blocked, s.action.isDestructive {
                Button {
                    if confirming {
                        confirming = false
                        state.quit(thing, confirmedCaution: s.verdict == .caution)
                    } else {
                        confirming = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { confirming = false }
                    }
                } label: {
                    Text(confirming ? (s.verdict == .caution ? "\(s.actionTitle) anyway?" : "Click to confirm") : s.actionTitle)
                        .frame(minWidth: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(s.verdict == .caution ? .orange : .accentColor)
                .controlSize(.small)
            }
            Spacer()
        }
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            configuration.icon.frame(width: 12)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Bar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(color).frame(width: max(2, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 3)
    }
    private var color: Color { fraction > 0.66 ? .orange : .accentColor.opacity(0.8) }
}

/// Real app icons for apps, SF Symbols for everything else.
struct ThingIcon: View {
    let thing: Thing

    var body: some View {
        if case .app(let bundle) = thing.kind {
            Image(nsImage: IconCache.icon(for: bundle)).resizable().interpolation(.high)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07))
                Image(systemName: thing.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }
}

enum IconCache {
    private static var cache: [String: NSImage] = [:]
    static func icon(for path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache[path] = i
        return i
    }
}
