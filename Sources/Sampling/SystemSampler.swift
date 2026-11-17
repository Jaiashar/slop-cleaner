import Darwin
import Foundation

/// Whole-machine numbers: CPU, memory, swap, pressure, heat.
final class SystemSampler {
    private let host = mach_host_self()
    private var lastBusy: UInt64 = 0
    private var lastTotal: UInt64 = 0
    private let pageSize: UInt64 = {
        var v: Int = 0
        var s = MemoryLayout<Int>.size
        sysctlbyname("hw.pagesize", &v, &s, nil, 0)
        return UInt64(v > 0 ? v : 16384)
    }()

    func sample(processCount: Int) -> SystemStats {
        var s = SystemStats()
        s.processCount = processCount
        s.cpuFraction = cpu()
        s.memoryUsed = memoryUsed()
        s.swapUsed = swap()
        s.pressureLevel = pressure()
        s.thermal = ProcessInfo.processInfo.thermalState
        return s
    }

    private func cpu() -> Double {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &load) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let t = load.cpu_ticks
        let user = UInt64(t.0), system = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { lastBusy = busy; lastTotal = total }
        guard lastTotal > 0, total > lastTotal else { return 0 }
        return min(1, max(0, Double(busy - lastBusy) / Double(total - lastTotal)))
    }

    private func memoryUsed() -> UInt64 {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        // Same idea as Activity Monitor's "Memory Used": app memory + wired + compressed.
        let app = UInt64(vm.internal_page_count) &- UInt64(vm.purgeable_count)
        return (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * pageSize
    }

    private func swap() -> UInt64 {
        var x = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &x, &size, nil, 0) == 0 else { return 0 }
        return x.xsu_used
    }

    private func pressure() -> Int {
        var v: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &size, nil, 0) == 0 else { return 1 }
        return Int(v)
    }
}
