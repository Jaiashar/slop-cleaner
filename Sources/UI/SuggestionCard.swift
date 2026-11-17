import AppKit
import SwiftUI

struct SuggestionCard: View {
    @EnvironmentObject var state: AppState
    let suggestion: Suggestion
    @State private var confirming = false

    private var tint: Color {
        switch suggestion.severity {
        case .urgent: return .red
        case .suggest: return .orange
        case .info: return .blue
        }
    }

    var body: some View {
        let s = suggestion
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                ZStack {
                    Circle().fill(tint.opacity(0.15))
                    Image(systemName: s.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(s.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(s.detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Snooze 1 hour") { state.snooze(s.id, for: 3600) }
                    Button("Snooze until tomorrow") { state.snoozeUntilTomorrow(s.id) }
                    Divider()
                    Button("Don't suggest this again") { state.ignore(s) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if !s.items.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(s.items, id: \.self) { row in
                        if let url = s.itemLinks[row] {
                            Button { NSWorkspace.shared.open(url) } label: {
                                HStack(spacing: 4) {
                                    Text(row).lineLimit(1).truncationMode(.middle)
                                    Image(systemName: "arrow.up.forward.square").font(.caption2)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Open this session in Claude (to archive it, or pick it back up)")
                        } else {
                            Text(row).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 43)
            }

            FlowChips(items: s.evidence)

            HStack(spacing: 8) {
                if let note = s.blockedNote {
                    Label(note, systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                } else if state.running.contains(s.id) {
                    ProgressView().controlSize(.small)
                    Text(workingText).font(.caption).foregroundStyle(.secondary)
                } else if s.action != .none {
                    Button {
                        if needsConfirm && !confirming {
                            confirming = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { confirming = false }
                        } else {
                            confirming = false
                            state.perform(s)
                        }
                    } label: {
                        Text(confirming ? "Click again to confirm" : s.actionTitle).frame(minWidth: 70)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(s.action.isDestructive ? tint : .accentColor)
                    .controlSize(.regular)
                }
                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.opacity(0.6))
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
    }

    /// Quitting a plain process gets a second click; shutting down a device (snapshot saved) doesn't.
    private var needsConfirm: Bool {
        switch suggestion.action {
        case .terminate, .quitApp: return true
        default: return false
        }
    }

    private var workingText: String {
        switch suggestion.action {
        case .stopEmulator, .shutdownSimulator: return "Shutting down…"
        default: return "Working…"
        }
    }
}

/// Small evidence chips that wrap onto new lines.
struct FlowChips: View {
    let items: [String]

    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary.opacity(0.7)))
            }
        }
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
