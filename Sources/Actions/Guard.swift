import AppKit
import Darwin
import Foundation
import Security

/// The last line of defense. Checked inside ActionRunner right before any process is stopped,
/// after every rule, button, sweep and Automate setting, using facts read at that moment.
/// Nothing in the app can stop a process without passing this.
enum Guard {
    /// Never stopped, whatever anything else says.
    static let neverNames: Set<String> = [
        // macOS itself
        "kernel_task", "launchd", "WindowServer", "loginwindow", "Finder", "Dock", "SystemUIServer", "ControlCenter",
        "NotificationCenter", "Spotlight", "WindowManager", "coreaudiod", "cfprefsd", "distnoted", "securityd",
        "trustd", "opendirectoryd", "powerd", "hidd", "logd", "mds", "mds_stores", "mdworker_shared", "backupd",
        "softwareupdated", "syspolicyd", "XprotectService", "TextInputMenuAgent", "CoreServicesUIAgent",
        "UserEventAgent", "usernoted", "sharingd", "bluetoothd", "airportd", "configd", "diskarbitrationd",
        // your shells and terminals (stopping them ends whatever you're running in them)
        "zsh", "-zsh", "bash", "-bash", "sh", "fish", "-fish", "login", "sshd", "tmux", "screen",
        // the apps this work runs inside
        "Claude", "Slop Cleaner", "disclaimer",
        // databases and infrastructure (they hold data; clients can reach them in ways a port check can't see)
        "postgres", "postmaster", "redis-server", "mysqld", "mongod", "mariadbd", "clickhouse", "etcd",
        "ssh-agent", "gpg-agent", "com.docker.backend", "com.docker.vmnetd", "Docker", "OrbStack", "OrbStack Helper",
        "colima", "limactl", "containerd", "dockerd",
    ]

    /// Folders that hold macOS's own components.
    static let neverPaths = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/",
                             "/Library/Developer/PrivateFrameworks/CoreSimulator", "/Applications/Claude.app/"]

    /// Apple-signed tools you run yourself (python3, make, yes...) may be stopped; other Apple-signed code may not.
    static let appleToolPaths = ["/usr/bin/", "/bin/", "/Library/Developer/CommandLineTools/",
                                 "/Applications/Xcode.app/Contents/Developer/"]

    struct Facts {
        var pid: Int32
        var uid: UInt32
        var name: String
        var path: String
        var applePlatform: Bool        // signed by Apple as part of macOS (unknown counts as true)
        var isFrontmost: Bool          // the app you're in right now
        var isRegularApp: Bool         // a normal app with a window and Dock icon
        var externalClients: Int       // connections from outside it to a port it listens on
        var sessionUsedAgo: TimeInterval? = nil   // Claude sessions: time since the Claude app last saw it used
        var ownerApp: String? = nil                // the open app it was started by, if any
        var parentSessionUsedAgo: TimeInterval? = nil  // started by a Claude session: when that session was last used
    }

    /// Apps you launch your own work from: what you start there is yours to stop.
    static let launcherApps: Set<String> = ["Ghostty", "Terminal", "iTerm2", "iTerm", "Warp", "WezTerm", "Alacritty", "kitty",
                                            "Cursor", "Code", "Visual Studio Code", "Xcode", "Android Studio", "Zed", "Claude"]

    /// Claude Code's own CLI lives inside a .app folder too, but it's a session, not part of an app.
    static func isClaudeCodeCLI(_ path: String) -> Bool { path.contains("/Claude/claude-code/") && path.hasSuffix("/claude") }

    enum Kind { case signal, politeAppQuit }

    /// nil = allowed. Otherwise the reason it's refused.
    static func refusal(_ f: Facts, kind: Kind, selfPID: Int32 = getpid()) -> String? {
        if f.pid <= 1 { return "it's part of macOS." }
        if f.pid == selfPID { return "that's Slop Cleaner itself." }
        if f.uid != getuid() { return "it belongs to macOS or another user." }
        if neverNames.contains(f.name) { return "\(f.name) is something your Mac or your work depends on." }
        // Apple's own apps (/System/Applications: Notes, Activity Monitor...) may get a polite ⌘Q, nothing more.
        let appleApp = kind == .politeAppQuit && f.isRegularApp && f.path.hasPrefix("/System/Applications/")
        if !appleApp, neverPaths.contains(where: { f.path.hasPrefix($0) }) { return "it's part of macOS." }
        if f.applePlatform {
            let userTool = appleToolPaths.contains { f.path.hasPrefix($0) }
            let politeApp = kind == .politeAppQuit && f.isRegularApp
            if !userTool && !politeApp { return "it's part of macOS." }
        }
        if kind == .signal, f.path.contains(".app/Contents/") || f.path.contains(".appex/"), !isClaudeCodeCLI(f.path) {
            return "it's part of an app (a helper, tab or extension). Quit the app itself if you want it gone."
        }
        if kind == .signal, let owner = f.ownerApp, !launcherApps.contains(owner) {
            return "it's part of \(owner)'s work. Quit \(owner) if you want it gone."
        }
        if kind == .signal && f.isRegularApp {
            return "it's an app, and apps are only ever asked to quit (⌘Q), so they can save your work."
        }
        if f.isFrontmost { return "you're using it right now." }
        if let ago = f.sessionUsedAgo, ago < 30 * 60 {
            return "this Claude session was used \(Format.ago(ago)), so it may still be working."
        }
        if let ago = f.parentSessionUsedAgo, ago < 30 * 60 {
            return "it belongs to a Claude session used \(Format.ago(ago)), which may still need it."
        }
        if f.externalClients > 0 {
            return "something is connected to it right now (\(f.externalClients) connection\(f.externalClients == 1 ? "" : "s"))."
        }
        return nil
    }

    // MARK: - Reading the facts live

    static func facts(pid: Int32) -> Facts? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        let path = n > 0 ? String(cString: buf) : ""
        let comm = withUnsafeBytes(of: kp.kp_proc.p_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let name = path.isEmpty ? comm : (path as NSString).lastPathComponent
        var front = false, regular = false
        let read = {
            // The app you're in, or any of its helper processes (a browser tab, a renderer...).
            if let app = NSWorkspace.shared.frontmostApplication {
                front = app.processIdentifier == pid
                if !front, let bundle = app.bundleURL?.path, !bundle.isEmpty, path.hasPrefix(bundle + "/") { front = true }
            }
            regular = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
        }
        if Thread.isMainThread { read() } else { DispatchQueue.main.sync(execute: read) }
        var f = Facts(pid: pid, uid: kp.kp_eproc.e_ucred.cr_uid, name: name, path: path,
                      applePlatform: isApplePlatform(pid), isFrontmost: front, isRegularApp: regular,
                      externalClients: externalClients(of: pid))
        f.ownerApp = owningApp(of: pid)
        f.parentSessionUsedAgo = parentSessionUsedAgo(of: pid)
        if name == "claude", let id = sessionID(of: pid) {
            let store = ClaudeSessionStore()
            if let r = store.records(for: [id])[id] {
                f.sessionUsedAgo = [r.lastActivity, r.lastFocused].compactMap { $0 }.max().map { Date().timeIntervalSince($0) }
            } else {
                f.sessionUsedAgo = 0      // can't find its record: treat as just used
            }
        }
        return f
    }

    /// The nearest open app (with a window) among its parents, e.g. ChatGPT for Codex's node workers.
    static func owningApp(of pid: Int32) -> String? {
        var cur = pid
        for _ in 0..<15 {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, cur]
            var kp = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
            let parent = kp.kp_eproc.e_ppid
            guard parent > 1 else { return nil }
            var name: String? = nil
            let read = {
                if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular {
                    name = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent
                }
            }
            if Thread.isMainThread { read() } else { DispatchQueue.main.sync(execute: read) }
            if let name { return name }
            cur = parent
        }
        return nil
    }

    /// If a Claude Code session started this (directly or through a shell), how long ago that session was used.
    static func parentSessionUsedAgo(of pid: Int32) -> TimeInterval? {
        var cur = pid
        for _ in 0..<15 {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, cur]
            var kp = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
            let parent = kp.kp_eproc.e_ppid
            guard parent > 1 else { return nil }
            var buf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(parent, &buf, 4096) > 0, isClaudeCodeCLI(String(cString: buf)) {
                guard let id = sessionID(of: parent) else { return 0 }
                let r = ClaudeSessionStore().records(for: [id])[id]
                guard let last = [r?.lastActivity, r?.lastFocused].compactMap({ $0 }).max() else { return 0 }
                return Date().timeIntervalSince(last)
            }
            cur = parent
        }
        return nil
    }

    /// The CLAUDE_CODE_HOST_SESSION_ID environment variable of a process, if it has one.
    static func sessionID(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 1 << 20
        var buf = [UInt8](repeating: 0, count: size)
        guard buf.withUnsafeMutableBytes({ sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }) == 0, size > 4 else { return nil }
        let prefix = Array("CLAUDE_CODE_HOST_SESSION_ID=".utf8)
        var i = 4
        while i < size {
            let s = i
            while i < size && buf[i] != 0 { i += 1 }
            if i - s > prefix.count && Array(buf[s..<(s + prefix.count)]) == prefix {
                return String(decoding: buf[(s + prefix.count)..<i], as: UTF8.self)
            }
            i += 1
        }
        return nil
    }

    /// Signed by Apple as part of macOS? If the signature can't be read, assume yes (refuse).
    static func isApplePlatform(_ pid: Int32) -> Bool {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return true }
        var req: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &req) == errSecSuccess, let req else { return true }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    /// Connections into ports the process (or its children) listens on, from anything outside that group.
    static func externalClients(of pid: Int32) -> Int {
        let all = ProcessSampler.allProcs()
        var children: [Int32: [Int32]] = [:]
        for kp in all { children[kp.kp_eproc.e_ppid, default: []].append(kp.kp_proc.p_pid) }
        var group = Set<Int32>([pid])
        var stack = [pid]
        while let cur = stack.popLast() {
            for c in children[cur] ?? [] where group.insert(c).inserted { stack.append(c) }
        }
        let sockets = SocketScanner.scan(pids: Array(group))
        let listening = Set(sockets.filter(\.listening).map(\.localPort))
        let internalPairs = Set(sockets.filter(\.established).map { "\($0.localPort)>\($0.remotePort)" })
        return sockets.filter { s in
            s.established && listening.contains(s.localPort)
                && !(s.remoteIsLocal && internalPairs.contains("\(s.remotePort)>\(s.localPort)"))
        }.count
    }
}
