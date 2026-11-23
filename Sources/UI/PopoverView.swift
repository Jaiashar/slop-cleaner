import SwiftUI

enum PopoverTab: String { case now, automate }

struct PopoverView: View {
    @EnvironmentObject var state: AppState
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Picker("", selection: $state.tab) {
                Text("Now").tag(PopoverTab.now)
                Text(state.pendingAuto.isEmpty ? "Automate" : "Automate · \(state.pendingAuto.count)").tag(PopoverTab.automate)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if state.tab == .now {
                        if state.uiQuery.isEmpty { WhyBusyView() }
                        if !state.uiQuery.isEmpty {
                            EmptyView()   // searching: just the results
                        } else if state.suggestions.isEmpty {
                            if !state.showsWhyBusy { AllQuietView() }
                        } else {
                            SuggestionsHeader()
                            VStack(spacing: 10) {
                                ForEach(state.suggestions) { s in SuggestionCard(suggestion: s) }
                            }
                        }
                        TopList()
                    } else {
                        AutomateView()
                    }
                }
                .padding(16)
            }
            .frame(height: 500)

            if let toast = state.toast {
                Text(toast)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.12))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Divider()
            FooterView(openSettings: openSettings)
        }
        .frame(width: 400)
        .animation(.easeOut(duration: 0.2), value: state.toast)
        .animation(.easeOut(duration: 0.2), value: state.suggestions)
    }
}

struct SectionTitle: View {
    let text: String
    var count: Int? = nil
    init(_ text: String, count: Int? = nil) { self.text = text; self.count = count }

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
    }
}

/// "🧹 Slop Cleaner        Cleaned today: 4 · 9.1 GB"
struct BrandRow: View {
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        HStack(spacing: 7) {
            BroomShape()
                .fill(LinearGradient(colors: [Color(red: 0.2, green: 0.83, blue: 0.6), Color(red: 0.05, green: 0.55, blue: 0.86)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing), style: FillStyle(eoFill: true))
                .frame(width: 18, height: 18)
            Text("Slop Cleaner").font(.headline)
            Spacer()
            let today = prefs.cleanedOn()
            let week = prefs.cleanedThisWeek()
            if today.count > 0 {
                Text("Cleaned today: \(today.count) · \(Format.bytes(today.bytes))")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("This week: \(week.count) things, \(Format.bytes(week.bytes)) of memory freed.")
            } else if week.count > 0 {
                Text("This week: \(week.count) · \(Format.bytes(week.bytes))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct BroomShape: Shape {
    func path(in rect: CGRect) -> Path { Path(BroomPath.path(in: rect)) }
}

struct SuggestionsHeader: View {
    @EnvironmentObject var state: AppState
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                SectionTitle("Worth a look", count: state.suggestions.count)
                let n = state.sweepableCount
                if state.running.contains("sweep-all") {
                    ProgressView().controlSize(.small)
                    Text("Sweeping…").font(.caption).foregroundStyle(.secondary)
                } else if n > 0 {
                    Button {
                        if confirming { confirming = false; state.sweepAll() }
                        else {
                            confirming = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { confirming = false }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            BroomShape().fill(style: FillStyle(eoFill: true)).frame(width: 12, height: 12)
                            Text(confirming ? "Sweep \(n) thing\(n == 1 ? "" : "s")?" : "Sweep")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(confirming ? .orange : .accentColor)
                    .help("Cleans up everything below that's safe right now. Each one is checked again just before.")
                }
            }
            let s = state.potentialSavings
            if s.memory > 0 || s.cpu >= 10 {
                Text("Following these would free \(Format.bytes(s.memory))" + (s.cpu >= 10 ? " and \(Format.cores(s.cpu))." : "."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Header

struct HeaderView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let s = state.stats
        VStack(alignment: .leading, spacing: 12) {
            BrandRow()
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CPU").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text("\(Int((s.cpuFraction * 100).rounded()))%")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(String(format: "%.1f of %d cores busy", s.cpuFraction * Double(s.cores), s.cores))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Sparkline(values: state.systemSeries, maxValue: 1, color: loadColor(s.cpuFraction))
                        .frame(width: 180, height: 46)
                    Text("last \(max(1, state.systemSeries.count * 5 / 60)) min")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 8) {
                StatPill(symbol: "memorychip", title: "Memory",
                         value: "\(Format.bytes(s.memoryUsed)) / \(Format.bytes(s.memoryTotal))",
                         tint: s.pressureLevel >= 4 ? .red : s.pressureLevel >= 2 ? .orange : .green)
                    .help("Memory in use, like Activity Monitor. Pressure is \(s.pressureText.lowercased()): " +
                          (s.pressureLevel >= 2 ? "macOS is squeezing memory, so closing big things will help."
                                                : "there's plenty of room, nothing to do."))
                StatPill(symbol: "arrow.left.arrow.right", title: "Swap", value: Format.bytes(s.swapUsed),
                         tint: s.pressureLevel >= 2 ? .orange : .secondary)
                    .help("Swap is overflow memory kept on the SSD. A few GB is normal on a Mac and harmless while memory pressure is OK. It only slows things down when pressure is up.")
                StatPill(symbol: "thermometer.medium", title: "Heat", value: s.thermalText,
                         tint: s.thermal == .nominal ? .green : s.thermal == .fair ? .yellow : .red)
            }
        }
    }

    private func loadColor(_ f: Double) -> Color { f >= 0.7 ? .red : f >= 0.4 ? .orange : .accentColor }
}

struct StatPill: View {
    let symbol: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(value).font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.6)))
    }
}

// MARK: - Empty state

struct AllQuietView: View {
    @EnvironmentObject var state: AppState

    /// Busy but nothing to clean: everything using the Mac is in use. Name the top two so it's clear why.
    private var busyBecause: String? {
        guard state.stats.cpuFraction >= 0.7 else { return nil }
        let top = state.things.sorted { $0.cpu > $1.cpu }.prefix(2).map { "\($0.title) (\(Format.cores($0.cpu)))" }
        return top.isEmpty ? nil : "Mostly " + top.joined(separator: " and ") + ", all in use."
    }

    var body: some View {
        let busy = busyBecause
        HStack(spacing: 12) {
            Image(systemName: busy == nil ? "sparkles" : "gauge.with.dots.needle.67percent")
                .font(.system(size: 24))
                .foregroundStyle(busy == nil ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(busy == nil ? "All clean" : "Busy, but nothing to clean").font(.headline)
                if let busy {
                    Text(busy).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if let p = state.peak {
                    Text("Busiest today: \(Int(p.cpu * 100))% at \(p.at.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Slop Cleaner will speak up if something is worth stopping.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill((busy == nil ? Color.green : Color.orange).opacity(0.08)))
    }
}

// MARK: - Footer

struct FooterView: View {
    @EnvironmentObject var state: AppState
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                Text("\(state.stats.processCount) processes · updated \(ago(state.lastUpdate))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        return s < 2 ? "just now" : s < 60 ? "\(s)s ago" : "\(s / 60) min ago"
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    let values: [Double]
    let maxValue: Double
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let top = max(maxValue, values.max() ?? 0)
            let step = size.width / CGFloat(max(1, values.count - 1))
            func y(_ v: Double) -> CGFloat { size.height - CGFloat(v / top) * (size.height - 2) - 1 }
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: y(v))
                i == 0 ? line.move(to: p) : line.addLine(to: p)
            }
            var fill = line
            fill.addLine(to: CGPoint(x: CGFloat(values.count - 1) * step, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0.02)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

/// "What's keeping your Mac busy": shown when it's warm or working hard, so loud fans always have an answer,
/// even when nothing is safe to clean.
struct WhyBusyView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let s = state.stats
        let warm = s.thermal != .nominal
        if state.showsWhyBusy, !state.things.isEmpty {
            let rows = HeatSource.breakdown(state.things, insights: state.insights) { t in
                let series = state.thingSeries[t.id] ?? []
                return series.count >= 3 ? series.suffix(12).reduce(0, +) / Double(min(12, series.count)) : t.cpu
            }
            let throttling = state.things.contains { $0.root.name == "kernel_task" && $0.cpu >= 15 }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(warm ? "Why your Mac is warm" : "What's keeping your Mac busy")
                ForEach(rows) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: r.source.symbol).frame(width: 16).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.source.title).font(.callout.weight(.medium))
                            Text(r.top.isEmpty ? r.source.note : r.top.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Text(Format.cores(r.cpu)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text(footnote(rows: rows, throttling: throttling))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.08)))
        }
    }

    private func footnote(rows: [HeatSource.Row], throttling: Bool) -> String {
        var parts: [String] = []
        let leftOn = rows.contains { $0.source == .leftOn }
        if state.suggestions.isEmpty && leftOn {
            parts.append("Some of it is left running, but none of it can be closed right now; open its row below to see why.")
        } else if state.suggestions.isEmpty {
            parts.append("None of it is safe to clean right now: it's all in use or part of macOS. Fans calm down as the work finishes.")
        } else {
            parts.append("The cards below are what's safe to clean; the rest is in use or part of macOS.")
        }
        if throttling { parts.append("macOS is slowing things a little to cool down (kernel_task).") }
        return parts.joined(separator: " ")
    }
}
