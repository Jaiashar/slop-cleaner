import Foundation

struct Classification {
    var things: [Thing]
    /// Devices something is driving right now: adb serials, simulator UDIDs, or "*android" / "*ios" for "all".
    var driven: Set<String>
}

/// Turns ~2,000 raw processes into the handful of things a person recognizes.
enum Classifier {
    static func classify(_ input: [ProcessSnapshot], simNames: [String: String] = [:],
                         sessions: [String: ClaudeSessionRecord] = [:],
                         origins: OriginCache? = nil,
                         home: String = NSHomeDirectory()) -> Classification {
        // Parents before children, so a walk from a parent claims its subtree first.
        let procs = input.sorted { $0.startTime < $1.startTime }
        var byPid: [Int32: ProcessSnapshot] = [:]
        var children: [Int32: [Int32]] = [:]
        for p in procs {
            byPid[p.pid] = p
            if p.ppid != p.pid { children[p.ppid, default: []].append(p.pid) }
        }

        var owner: [Int32: String] = [:]
        var things: [String: Thing] = [:]
        var order: [String] = []

        func add(_ t: Thing) {
            for p in t.processes { owner[p.pid] = t.id }
            if things[t.id] == nil { order.append(t.id) }
            things[t.id] = t
        }
        func subtree(_ pid: Int32) -> [ProcessSnapshot] {
            var out: [ProcessSnapshot] = []
            var stack = [pid]
            while let cur = stack.popLast() {
                guard owner[cur] == nil, let p = byPid[cur] else { continue }
                out.append(p)
                owner[cur] = "_pending"
                stack.append(contentsOf: children[cur] ?? [])
            }
            return out
        }

        // 1. Android emulators.
        for p in procs where p.name.hasPrefix("qemu-system") && owner[p.pid] == nil {
            let avd = value(after: "-avd", in: p.args) ?? "Android"
            let port = value(after: "-port", in: p.args) ?? "5554"
            let serial = "emulator-\(port)"
            var members = subtree(p.pid)
            if let parent = byPid[p.ppid], parent.name == "emulator", owner[parent.pid] == nil {
                members.insert(parent, at: 0)
                members.swapAt(0, 1)
            }
            add(Thing(id: "emu:\(serial)", kind: .androidEmulator(serial: serial, avd: avd),
                      title: "\(friendlyAVD(avd)) emulator", subtitle: serial, processes: members))
        }

        // 2. iOS simulators: everything under each launchd_sim.
        for p in procs where p.name == "launchd_sim" && owner[p.pid] == nil {
            guard let udid = firstUUID(in: p.args.joined(separator: " ") + " " + p.path) else { continue }
            let name = simNames[udid] ?? "iOS Simulator"
            add(Thing(id: "sim:\(udid)", kind: .iosSimulator(udid: udid, name: name),
                      title: name, subtitle: "Simulator · \(udid.prefix(8))", processes: subtree(p.pid)))
        }

        // 3. Claude Code sessions. Tools they started (tests, servers) become their own things.
        for p in procs where isClaudeSession(p) && owner[p.pid] == nil {
            let folder = folderLabel(p.cwd, home: home)
            let sessionID = "claude:\(p.key)"
            let sessionTitle = p.hostSessionID.flatMap { sessions[$0]?.title }
            var members: [ProcessSnapshot] = []
            if let parent = byPid[p.ppid], parent.path.hasSuffix("/disclaimer"), owner[parent.pid] == nil {
                members.append(parent)
                owner[parent.pid] = sessionID
            }
            var stack = [p.pid]
            while let cur = stack.popLast() {
                guard owner[cur] == nil, let q = byPid[cur] else { continue }
                let label = sessionTitle.map { "Started by the Claude session “\($0)”" }
                    ?? "Started by the Claude session in \(folder ?? "a session")"
                if cur != p.pid, let tool = toolKind(q) {
                    var t = toolThing(q, tool, subtree(cur), owner: label, home: home)
                    t.ownerID = sessionID
                    add(t)
                    continue
                }
                // A command the session ran through its shell is its own thing, so a stuck one can be seen.
                if cur != p.pid, !shells.contains(q.name), let parent = byPid[q.ppid], shells.contains(parent.name) {
                    let members = subtree(cur)
                    var t = Thing(id: "proc:\(q.key)", kind: .process, title: q.name,
                                  subtitle: folderLabel(q.cwd, home: home).map { "in \($0)" } ?? "pid \(q.pid)",
                                  processes: members.isEmpty ? [q] : members, ownerLabel: label)
                    t.ownerID = sessionID
                    add(t)
                    continue
                }
                members.append(q)
                owner[cur] = sessionID
                stack.append(contentsOf: children[cur] ?? [])
            }
            // The session process itself goes first.
            if let i = members.firstIndex(where: { $0.pid == p.pid }), i != 0 { members.swapAt(0, i) }
            let record = p.hostSessionID.flatMap { sessions[$0] }
            var session = Thing(id: sessionID, kind: .claudeSession, title: record?.title ?? "Claude Code session",
                                subtitle: "Claude Code" + (folder.map { " · \($0)" } ?? ""), processes: members)
            if let r = record { session.externalLastUse = [r.lastActivity, r.lastFocused].compactMap { $0 }.max() }
            add(session)
        }

        // 4. Dev servers, test runs and build daemons started from anywhere else.
        for p in procs where owner[p.pid] == nil {
            guard let tool = toolKind(p) else { continue }
            add(toolThing(p, tool, subtree(p.pid), owner: nil, home: home))
        }

        // 5. Apps: helpers roll up into their .app bundle.
        var appMembers: [String: [ProcessSnapshot]] = [:]
        var appOrder: [String] = []
        for p in procs where owner[p.pid] == nil {
            guard let bundle = appBundle(p.path), !p.path.contains(".app/Contents/Developer/"),
                  p.uid >= 500 || bundle.hasPrefix("/Applications") else { continue }
            if appMembers[bundle] == nil { appOrder.append(bundle) }
            appMembers[bundle, default: []].append(p)
            owner[p.pid] = "app:\(bundle)"
        }
        for bundle in appOrder {
            var members = appMembers[bundle]!
            // Put the main executable (the one at Contents/MacOS directly under the bundle) first.
            if let i = members.firstIndex(where: { $0.path.hasPrefix(bundle + "/Contents/MacOS/") }), i != 0 {
                members.swapAt(0, i)
            }
            let n = members.count
            add(Thing(id: "app:\(bundle)", kind: .app(bundlePath: bundle), title: appName(bundle),
                      subtitle: n == 1 ? "1 process" : "\(n) processes", processes: members))
        }

        // 6. Everything else, one thing per process.
        for p in procs where owner[p.pid] == nil {
            let isSystem = p.uid < 500
            let sub = isSystem ? "System · pid \(p.pid)" : (folderLabel(p.cwd, home: home).map { "in \($0)" } ?? "pid \(p.pid)")
            add(Thing(id: (isSystem ? "sys:" : "proc:") + p.key, kind: isSystem ? .system : .process,
                      title: p.name, subtitle: sub, processes: [p]))
        }

        // Where each tool or loose process came from (a terminal you typed in, or a Claude session).
        for id in order {
            guard var t = things[id], t.ownerLabel == nil else { continue }
            switch t.kind {
            case .devServer, .testRun, .buildDaemon, .process, .androidEmulator:
                let o = origins.map { $0.value(for: t.root.key) { origin(of: t.root, byPid: byPid, owner: owner, things: things) } }
                    ?? origin(of: t.root, byPid: byPid, owner: owner, things: things)
                t.origin = o?.text
                t.originApp = o?.app
                things[id] = t
            default:
                break
            }
        }

        var result = order.compactMap { things[$0] }
        let viewers = attachedViewers(procs)
        for i in result.indices {
            if case .iosSimulator(let udid, _) = result[i].kind, let v = viewers[udid] { result[i].origin = "\(v.capitalizedFirst) is attached to it" }
        }
        return Classification(things: result, driven: drivenDevices(procs))
    }

    static let terminalApps = ["Ghostty", "Terminal", "iTerm2", "iTerm", "Warp", "WezTerm", "Alacritty", "kitty",
                               "Cursor", "Code", "Visual Studio Code", "Android Studio", "Xcode", "Zed"]

    struct Origin: Hashable {
        var text: String
        /// The open app it came from; nil for a Claude session or when only the command is known.
        var app: String? = nil
    }

    /// Walks up the parent chain: a Claude session, or a terminal app with the command that was typed.
    static func origin(of p: ProcessSnapshot, byPid: [Int32: ProcessSnapshot], owner: [Int32: String],
                       things: [String: Thing]) -> Origin? {
        var command: String? = nil
        var sawShell = false
        var cur = byPid[p.ppid]
        var hops = 0
        while let q = cur, q.pid > 1, hops < 12 {
            if let o = owner[q.pid], o.hasPrefix("claude:"), let s = things[o] {
                return Origin(text: s.title == "Claude Code session" ? "Started by a Claude session (\(s.subtitle))"
                                                                    : "Started by the Claude session “\(s.title)”")
            }
            if let o = owner[q.pid], o.hasPrefix("app:"), let a = things[o], q.path.contains("/Contents/MacOS/") {
                let name = a.title
                let cmd = command.map { ": \($0)" } ?? ""
                return Origin(text: terminalApps.contains(name) ? "Started from your terminal (\(name))\(cmd)" : "Started by \(name)\(cmd)",
                              app: name)
            }
            let isShell = ["zsh", "-zsh", "bash", "-bash", "sh", "fish", "-fish", "login"].contains(q.name)
            // The typed command is the last non-shell below the interactive shell.
            if isShell, command != nil { sawShell = true }
            if !isShell, !sawShell, !q.args.isEmpty {
                command = q.args.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
            }
            cur = byPid[q.ppid]
            hops += 1
        }
        // Its parents are gone (e.g. the session that ran it ended): all that's left is the command.
        return command.map { Origin(text: "Started by \($0)") }
    }

    // MARK: - Detection helpers

    static func isClaudeSession(_ p: ProcessSnapshot) -> Bool {
        guard p.name == "claude" else { return false }
        return p.path.contains("/claude-code/") || p.path.contains("/.local/") || p.path.contains("/claude/")
            || p.path.hasSuffix("/bin/claude")
    }

    static let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "sh", "fish", "-fish", "dash"]

    static let interpreters: Set<String> = ["node", "bun", "deno", "ruby", "java", "npm", "npx", "pnpm", "yarn"]

    static func toolKind(_ p: ProcessSnapshot) -> (ThingKind, String)? {
        let exe = p.name.lowercased()
        if exe == "xcodebuild" { return (.testRun, "Xcode build") }
        let isInterp = interpreters.contains(exe) || exe.hasPrefix("python") || exe == "pytest" || exe == "uvicorn"
        guard isInterp else { return nil }
        let a = p.args.dropFirst().joined(separator: " ").lowercased()
        if a.contains("org.gradle.launcher.daemon") { return (.buildDaemon, "Gradle daemon") }
        if a.contains("kotlincompiledaemon") || a.contains("kotlin-daemon") { return (.buildDaemon, "Kotlin daemon") }
        if a.contains("gradlewrappermain") { return (.testRun, "Gradle build") }
        if a.contains("maestro") { return (.testRun, "Maestro flow") }
        if exe == "pytest" || a.contains("pytest") { return (.testRun, "pytest run") }
        if a.contains("jest") || a.contains("vitest") { return (.testRun, "JS test run") }
        if a.contains("expo") && a.contains(" start") { return (.devServer, "Expo dev server") }
        if a.contains("react-native start") || a.contains("metro") { return (.devServer, "Metro bundler") }
        if a.contains("next dev") || a.contains("next-server") { return (.devServer, "Next.js dev server") }
        if a.contains("vite") { return (.devServer, "Vite dev server") }
        if a.contains("webpack") && a.contains("serve") { return (.devServer, "Webpack dev server") }
        if exe == "uvicorn" || a.contains("uvicorn") { return (.devServer, "Uvicorn server") }
        if a.contains("runserver") { return (.devServer, "Django server") }
        if a.contains("flask run") { return (.devServer, "Flask server") }
        if ["npm", "pnpm", "yarn", "bun"].contains(exe) && (a.contains("run dev") || a.hasSuffix(" dev") || a == "dev") {
            return (.devServer, "Dev server")
        }
        return nil
    }

    private static func toolThing(_ root: ProcessSnapshot, _ tool: (ThingKind, String), _ members: [ProcessSnapshot],
                                  owner: String?, home: String) -> Thing {
        let folder = folderLabel(root.cwd, home: home)
        return Thing(id: "tool:\(root.key)", kind: tool.0, title: tool.1,
                     subtitle: folder.map { "in \($0)" } ?? "pid \(root.pid)",
                     processes: members.isEmpty ? [root] : members, ownerLabel: owner)
    }

    /// Viewers that keep a device open without driving it, e.g. the Claude app's simulator panel.
    static func attachedViewers(_ procs: [ProcessSnapshot]) -> [String: String] {
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: String] = [:]
        for p in procs where p.name == "simctl" {
            let joined = p.args.joined(separator: " ")
            guard isViewer(simctlArgs: joined), let u = firstUUID(in: joined) else { continue }
            var viewer = "a log viewer"
            var cur = byPid[p.ppid]
            var hops = 0
            while let q = cur, q.pid > 1, hops < 6 {
                if let b = appBundle(q.path) { viewer = "the \(appName(b)) app's simulator panel"; break }
                cur = byPid[q.ppid]; hops += 1
            }
            out[u] = viewer
        }
        return out
    }

    /// Who is driving which device. Only real executables count, never a shell line that mentions them.
    static func drivenDevices(_ procs: [ProcessSnapshot]) -> Set<String> {
        var d = Set<String>()
        for p in procs {
            let exe = p.name
            let joined = p.args.joined(separator: " ")
            switch exe {
            case "adb":
                if isAdbServer(p) { break }
                // `adb -s <serial> …` drives that one; plain `adb shell`, `adb -e` or ANDROID_SERIAL could be
                // any emulator, so it counts for all of them (never close one mid-command).
                d.insert(value(after: "-s", in: p.args) ?? "*android")
            case "xcodebuild", "simctl", "idb":
                if exe == "simctl" && isViewer(simctlArgs: joined) { break }
                if let u = firstUUID(in: joined) { d.insert(u) }
            case "idb_companion":
                // idb's companion is a server that stays up (often orphaned) long after the last command.
                // It only counts while it's actually serving something.
                if p.cpu >= 5, let u = firstUUID(in: joined) { d.insert(u) }
            case "java", "maestro":
                let lower = joined.lowercased()
                if lower.contains("maestro") {
                    if let dev = value(after: "--device", in: p.args) ?? value(after: "--udid", in: p.args) {
                        d.insert(dev)
                    } else {
                        d.insert("*android"); d.insert("*ios")
                    }
                }
                if lower.contains("connected") && lower.contains("androidtest") { d.insert("*android") }
            default:
                break
            }
        }
        return d
    }

    // MARK: - Small parsers

    /// simctl watching a simulator without driving it: streaming its log or screen, or waiting on
    /// notifications (the Claude app's simulator panel runs `simctl spawn <udid> notifyutil -w …`).
    static func isViewer(simctlArgs a: String) -> Bool {
        a.contains("log stream") || a.contains(" io ") || (a.contains(" spawn ") && a.contains("notifyutil") && a.contains(" -w "))
    }

    /// adb's background server (`adb fork-server server`, `adb start-server`...), not a command someone ran.
    /// It keeps a connection open to every running emulator, so it never means anyone is using one.
    static func isAdbServer(_ p: ProcessSnapshot) -> Bool {
        guard p.name == "adb" else { return false }
        // The command is the first word after adb's own options (-s/-t/-H/-P/-L take a value).
        let withValue: Set<String> = ["-s", "-t", "-H", "-P", "-L", "--one-device"]
        var i = 1
        while i < p.args.count, p.args[i].hasPrefix("-") { i += withValue.contains(p.args[i]) ? 2 : 1 }
        guard i < p.args.count else { return false }
        return ["server", "fork-server", "start-server", "kill-server", "nodaemon"].contains(p.args[i])
    }

    static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func firstUUID(in s: String) -> String? {
        let pattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        guard let r = s.range(of: pattern, options: .regularExpression) else { return nil }
        return String(s[r]).uppercased()
    }

    static func appBundle(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    static func appName(_ bundle: String) -> String {
        let last = (bundle as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// "Pixel_8_API_35" → "Pixel 8 API 35".
    static func friendlyAVD(_ avd: String) -> String {
        avd.replacingOccurrences(of: "_", with: " ")
    }

    /// A short, recognizable folder name: a worktree's name, or the last two path parts.
    static func folderLabel(_ cwd: String?, home: String) -> String? {
        guard let cwd, !cwd.isEmpty, cwd != "/" else { return nil }
        for marker in ["/.worktrees/", "/.claude/worktrees/", "/worktrees/"] {
            if let r = cwd.range(of: marker) {
                let rest = cwd[r.upperBound...]
                if let name = rest.split(separator: "/").first { return "\(name) worktree" }
            }
        }
        if cwd == home { return "~" }
        var parts = cwd.split(separator: "/").map(String.init)
        if cwd.hasPrefix(home + "/") {
            parts = Array(cwd.dropFirst(home.count + 1).split(separator: "/").map(String.init))
            if parts.count == 1 { return "~/\(parts[0])" }
        }
        return parts.suffix(2).joined(separator: "/")
    }
}

/// Remembers each process's origin; a process's parents never change while it lives.
final class OriginCache {
    private var map: [String: Classifier.Origin?] = [:]
    private var touched = Set<String>()

    func value(for key: String, compute: () -> Classifier.Origin?) -> Classifier.Origin? {
        touched.insert(key)
        if let v = map[key] { return v }
        let v = compute()
        map[key] = v
        if map.count > touched.count * 2 + 500 {      // forget processes that are gone
            map = map.filter { touched.contains($0.key) }
            touched = []
        }
        return v
    }
}
