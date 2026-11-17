import Darwin
import Foundation

/// Reads every process through libproc. Confined to one serial queue.
///
/// Own-user processes give exact CPU time and memory footprint. Root and other users'
/// processes refuse `proc_pid_rusage`, so for those we fall back to the setuid `/bin/ps`,
/// refreshed every 30 s.
final class ProcessSampler {
    private struct Static { let path: String; let args: [String]; let cwd: String?; var session: String? = nil }

    private var statics: [String: Static] = [:]
    private var lastCPUTime: [String: UInt64] = [:]
    private var lastSampleNs: UInt64 = 0
    private var otherUsers: [Int32: (cpu: Double, rss: UInt64)] = [:]
    private var lastPS = Date.distantPast
    private let numer: UInt64
    private let denom: UInt64
    private let myUID = getuid()
    private var argBuffer: [UInt8]

    init() {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        numer = UInt64(tb.numer)
        denom = UInt64(tb.denom)
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        sysctl(&mib, 2, &argmax, &size, nil, 0)
        argBuffer = [UInt8](repeating: 0, count: max(Int(argmax), 262_144))
    }

    func sample(now: Date = Date()) -> [ProcessSnapshot] {
        let procs = Self.allProcs()
        let nowNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = lastSampleNs == 0 ? 0 : Double(nowNs - lastSampleNs)
        lastSampleNs = nowNs
        if now.timeIntervalSince(lastPS) > 30 {
            refreshOtherUsers()
            lastPS = now
        }

        var out: [ProcessSnapshot] = []
        out.reserveCapacity(procs.count)
        var seen = Set<String>()
        for kp in procs {
            let pid = kp.kp_proc.p_pid
            if pid <= 0 { continue }
            let tv = kp.kp_proc.p_un.__p_starttime
            let start = Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
            let key = "\(pid)@\(Int(start.timeIntervalSince1970 * 1000))"
            seen.insert(key)
            let uid = kp.kp_eproc.e_ucred.cr_uid

            let st: Static
            if let cached = statics[key] {
                st = cached
            } else {
                st = loadStatic(pid: pid, uid: uid)
                statics[key] = st
            }

            var cpu = 0.0
            var mem: UInt64 = 0
            if let ru = Self.rusage(pid) {
                let ns = (ru.ri_user_time + ru.ri_system_time) * numer / denom
                if let prev = lastCPUTime[key], elapsed > 0, ns >= prev {
                    cpu = Double(ns - prev) / elapsed * 100
                }
                lastCPUTime[key] = ns
                mem = ru.ri_phys_footprint
            } else if let o = otherUsers[pid] {
                cpu = o.cpu
                mem = o.rss
            }

            let comm = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw -> String in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            let name = st.path.isEmpty ? comm : (st.path as NSString).lastPathComponent

            out.append(ProcessSnapshot(
                pid: pid, ppid: kp.kp_eproc.e_ppid, uid: uid, name: name, path: st.path,
                args: st.args, cwd: st.cwd, startTime: start, cpu: cpu, memory: mem, hostSessionID: st.session))
        }

        if statics.count > seen.count + 64 {
            statics = statics.filter { seen.contains($0.key) }
            lastCPUTime = lastCPUTime.filter { seen.contains($0.key) }
        }
        return out
    }

    // MARK: - Per-process static info (read once)

    private func loadStatic(pid: pid_t, uid: uid_t) -> Static {
        var pathBuf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        let path = n > 0 ? String(cString: pathBuf) : ""
        guard uid == myUID else { return Static(path: path, args: [], cwd: nil) }
        let wantsSession = path.hasSuffix("/claude")
        let (args, session) = readArgs(pid, sessionVar: wantsSession)
        return Static(path: path, args: args, cwd: Self.cwd(pid), session: session)
    }

    /// Arguments, plus (for Claude sessions only) the one environment variable naming its session.
    private func readArgs(_ pid: pid_t, sessionVar: Bool) -> ([String], String?) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argBuffer.count
        let ok = argBuffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, 3, raw.baseAddress, &size, nil, 0) == 0
        }
        guard ok, size > 4 else { return ([], nil) }
        let argc = argBuffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size && argBuffer[i] != 0 { i += 1 }   // exec path
        while i < size && argBuffer[i] == 0 { i += 1 }   // padding
        var result: [String] = []
        while result.count < Int(argc) && i < size && result.count < 64 {
            let s = i
            while i < size && argBuffer[i] != 0 { i += 1 }
            let end = min(i, s + 400)                        // shell one-liners can be huge
            result.append(String(decoding: argBuffer[s..<end], as: UTF8.self))
            i += 1
        }
        guard sessionVar else { return (result, nil) }
        // Skip any remaining args, then scan the environment for just this one variable.
        let prefix = Array("CLAUDE_CODE_HOST_SESSION_ID=".utf8)
        while i < size {
            let s = i
            while i < size && argBuffer[i] != 0 { i += 1 }
            if i - s > prefix.count && Array(argBuffer[s..<(s + prefix.count)]) == prefix {
                return (result, String(decoding: argBuffer[(s + prefix.count)..<i], as: UTF8.self))
            }
            i += 1
        }
        return (result, nil)
    }

    private static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard r > 0 else { return nil }
        let s = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return s.isEmpty ? nil : s
    }

    // MARK: - System calls

    static func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return r == 0 ? info : nil
    }

    static func allProcs() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        size += size / 8
        let stride = MemoryLayout<kinfo_proc>.stride
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        var bytes = buf.count * stride
        guard sysctl(&mib, 4, &buf, &bytes, nil, 0) == 0 else { return [] }
        return Array(buf.prefix(bytes / stride))
    }

    /// Start time of a live pid, to make sure a pid still means the same process.
    static func startTime(of pid: pid_t) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = kp.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    private func refreshOtherUsers() {
        guard let text = Shell.run("/bin/ps", ["-axo", "pid=,pcpu=,rss="], timeout: 5)?.output else { return }
        var map: [Int32: (Double, UInt64)] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = Int32(f[0]), let cpu = Double(f[1]), let rss = UInt64(f[2]) else { continue }
            map[pid] = (cpu, rss * 1024)
        }
        otherUsers = map
    }
}
