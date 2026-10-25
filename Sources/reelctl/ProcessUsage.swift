import Darwin
import Foundation

/// One `proc_pid_rusage(RUSAGE_INFO_V6)` sample of a process (design section 7.9): CPU time,
/// wakeups, billed energy and instructions. Reading a process of the same user needs no
/// privileges.
struct ProcessUsage: Sendable, Hashable {
    var pid: pid_t
    /// User plus system CPU time in nanoseconds.
    var cpuNanos: UInt64
    var interruptWakeups: UInt64
    var packageIdleWakeups: UInt64
    var billedEnergyNanojoules: UInt64
    var instructions: UInt64
    var sampledAtNanos: UInt64

    /// The current usage of `pid`, or nil when the process is gone or cannot be read.
    static func sample(_ pid: pid_t = getpid()) -> ProcessUsage? {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        guard status == 0 else { return nil }
        // ri_user_time and ri_system_time are Mach absolute time units (ticks on Apple Silicon).
        let ticks = info.ri_user_time &+ info.ri_system_time
        return ProcessUsage(
            pid: pid,
            cpuNanos: machToNanos(ticks),
            interruptWakeups: info.ri_interrupt_wkups,
            packageIdleWakeups: info.ri_pkg_idle_wkups,
            billedEnergyNanojoules: info.ri_billed_energy,
            instructions: info.ri_instructions,
            sampledAtNanos: DispatchTime.now().uptimeNanoseconds
        )
    }

    private static let timebase: mach_timebase_info_data_t = {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return base
    }()

    static func machToNanos(_ ticks: UInt64) -> UInt64 {
        let base = timebase
        guard base.denom != 0 else { return ticks }
        return UInt64((Double(ticks) * Double(base.numer) / Double(base.denom)).rounded())
    }

    /// The work done between `earlier` and `self`.
    func since(_ earlier: ProcessUsage) -> Delta {
        let wall = Double(sampledAtNanos &- earlier.sampledAtNanos) / 1e9
        let cpu = Double(cpuNanos &- earlier.cpuNanos) / 1e9
        let wakeups = (interruptWakeups &- earlier.interruptWakeups) &+ (packageIdleWakeups &- earlier.packageIdleWakeups)
        return Delta(
            wallSeconds: wall,
            cpuSeconds: cpu,
            cpuPercent: wall > 0 ? cpu / wall * 100 : 0,
            interruptWakeups: interruptWakeups &- earlier.interruptWakeups,
            packageIdleWakeups: packageIdleWakeups &- earlier.packageIdleWakeups,
            wakeupsPerSecond: wall > 0 ? Double(wakeups) / wall : 0,
            billedEnergyNJ: billedEnergyNanojoules &- earlier.billedEnergyNanojoules,
            instructions: instructions &- earlier.instructions
        )
    }

    struct Delta: Encodable, Sendable, Hashable {
        var wallSeconds: Double
        var cpuSeconds: Double
        /// Of one core.
        var cpuPercent: Double
        var interruptWakeups: UInt64
        var packageIdleWakeups: UInt64
        /// Interrupt plus package idle wakeups per second.
        var wakeupsPerSecond: Double
        var billedEnergyNJ: UInt64
        var instructions: UInt64
    }

    // MARK: Other processes

    /// PIDs of this user's processes named `name` (`proc_listpids` and `proc_name`).
    static func pids(named name: String) -> Set<pid_t> {
        let uid = getuid()
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard needed > 0 else { return [] }
        // Room for processes started between the two calls.
        let capacity = Int(needed) / MemoryLayout<pid_t>.size + 64
        var buffer = [pid_t](repeating: 0, count: capacity)
        let filled = buffer.withUnsafeMutableBytes { bytes in
            proc_listpids(UInt32(PROC_UID_ONLY), uid, bytes.baseAddress, Int32(bytes.count))
        }
        guard filled > 0 else { return [] }
        let count = Int(filled) / MemoryLayout<pid_t>.size
        var found: Set<pid_t> = []
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        for pid in buffer.prefix(count) where pid > 0 {
            let length = nameBuffer.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
            guard length > 0 else { continue }
            let processName = nameBuffer.withUnsafeBufferPointer { pointer in
                String(decoding: pointer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            if processName == name { found.insert(pid) }
        }
        return found
    }
}
