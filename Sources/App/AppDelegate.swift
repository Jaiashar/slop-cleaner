import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var state: AppState!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var bag: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests host inside the app; don't start watching or ask for notifications there.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        state = AppState()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = "Slop Cleaner"
        }

        let root = PopoverView(openSettings: { [weak self] in self?.showSettings() })
            .environmentObject(state)
            .environmentObject(state.prefs)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        state.onOpenRequest = { [weak self] in self?.showPopover() }
        Publishers.CombineLatest(state.$stats, state.$suggestions)
            .receive(on: RunLoop.main)
            .sink { [weak self] stats, suggestions in self?.updateIcon(stats, suggestions) }
            .store(in: &bag)
        state.start()

        observeDebugAct()

        // Debug hook: `scripts/snapshot.sh` asks Watcher to render its own popover to a PNG.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("slopcleaner.debug.snapshot"), object: nil, queue: .main
        ) { [weak self] note in
            // object: "path|tab|search" — tab is now/automate; search expands the first match.
            let parts = (note.object as? String ?? "").components(separatedBy: "|")
            guard let self else { return }
            let mode = parts.count > 1 ? parts[1] : "now"
            if mode.hasPrefix("demo") {
                self.state.loadDemo(tab: mode == "demo-automate" ? .automate : .now)
                self.snapshotPopover(to: parts.first ?? NSTemporaryDirectory() + "demo.png") { self.state.exitDemo() }
                return
            }
            self.state.tab = mode == "automate" ? .automate : .now
            self.state.uiQuery = parts.count > 2 ? parts[2] : ""
            self.state.uiExpanded = []
            if parts.count > 2, !parts[2].isEmpty {
                let q = parts[2]
                if let t = self.state.things.first(where: { $0.title.localizedCaseInsensitiveContains(q)
                    || $0.subtitle.localizedCaseInsensitiveContains(q) || $0.listenPorts.contains { String($0) == q } }) {
                    self.state.uiExpanded = [t.id]
                }
            }
            self.snapshotPopover(to: parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory() + "watcher-popover.png")
        }
    }

    /// Debug hook: press a suggestion's button by id, exactly as the card's button does.
    private func observeDebugAct() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("slopcleaner.debug.act"), object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.object as? String else { return }
            self?.state.performByID(id)
        }
    }

    private func snapshotPopover(to path: String, then: (() -> Void)? = nil) {
        let wasShown = popover.isShown
        if !wasShown { showPopover() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let view = self.popover.contentViewController?.view.window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            // The menu bar icon too, at 4x, in light and dark.
            for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let stats = self.state.stats
                let icon = GaugeIcon.make(fraction: max(0.6, stats.cpuFraction), alert: .suggest,
                                          appearance: NSAppearance(named: look)!)
                let big = NSImage(size: NSSize(width: 72, height: 72), flipped: false) { r in
                    (look == .darkAqua ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                    r.fill()
                    icon.draw(in: r)
                    return true
                }
                if let tiff = big.tiffRepresentation, let b = NSBitmapImageRep(data: tiff) {
                    try? b.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".icon-\(name).png"))
                }
            }
            if !wasShown { self.popover.performClose(nil) }
            then?()
        }
    }

    /// Opening the app again (Spotlight, Finder, `open`) shows the popover.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if state != nil { showPopover() }
        return false
    }

    // MARK: - Menu bar icon

    private var iconKey = ""

    private func updateIcon(_ stats: SystemStats, _ suggestions: [Suggestion]) {
        guard let button = statusItem?.button else { return }
        let level: Severity? = suggestions.map(\.severity).filter { $0 >= .suggest }.max()
        // Redraw only when what the icon shows changes (dust level, dot, light/dark).
        let dust = stats.cpuFraction >= 0.8 ? 3 : stats.cpuFraction >= 0.55 ? 2 : stats.cpuFraction >= 0.3 ? 1 : 0
        let key = "\(dust)|\(level?.rawValue ?? -1)|\(button.effectiveAppearance.name.rawValue)"
        if key != iconKey {
            iconKey = key
            button.image = GaugeIcon.make(fraction: stats.cpuFraction, alert: level, appearance: button.effectiveAppearance)
        }
        let n = suggestions.filter { $0.severity >= .suggest }.count
        button.toolTip = n == 0 ? "Slop Cleaner · CPU \(Int(stats.cpuFraction * 100))%"
                                : "Slop Cleaner · \(n) thing\(n == 1 ? "" : "s") worth a look"
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        popover.isShown ? popover.performClose(sender) : showPopover()
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        state.popoverVisible = true
        state.refresh()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) { state.popoverVisible = false }

    // MARK: - Settings

    func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(sendTest: { [weak self] in self?.state.notifier.sendTest() })
                .environmentObject(state.prefs))
            let w = NSWindow(contentViewController: host)
            w.title = "Slop Cleaner Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// The menu bar glyph: a little broom. Dust specks appear as the CPU gets busier, and an orange
/// or red dot shows when there's something worth cleaning.
enum GaugeIcon {
    static func make(fraction: Double, alert: Severity?, appearance: NSAppearance) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ink = isDark ? NSColor.white : NSColor.black
        let img = NSImage(size: size, flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.addPath(BroomPath.path(in: CGRect(x: 1.5, y: 0.5, width: 16, height: 16)))
            cg.setFillColor(ink.cgColor)
            cg.fillPath(using: .evenOdd)

            // Dust by the bristles: one speck per level of load.
            let specks = fraction >= 0.8 ? 3 : fraction >= 0.55 ? 2 : fraction >= 0.3 ? 1 : 0
            let spots = [CGPoint(x: 2.0, y: 16.3), CGPoint(x: 4.6, y: 17.0), CGPoint(x: 1.0, y: 13.6)]
            cg.setFillColor(ink.withAlphaComponent(0.75).cgColor)
            for p in spots.prefix(specks) { cg.fillEllipse(in: CGRect(x: p.x - 0.9, y: p.y - 0.9, width: 1.8, height: 1.8)) }

            if let alert {
                let dot = CGRect(x: rect.maxX - 6.4, y: rect.maxY - 6.4, width: 6.2, height: 6.2)
                cg.setFillColor((alert == .urgent ? NSColor.systemRed : NSColor.systemOrange).cgColor)
                cg.fillEllipse(in: dot)
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}
