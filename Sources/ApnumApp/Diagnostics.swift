import Darwin
import Foundation

/// Live resource use of this process, for Settings › About › Diagnostics. Reads the same numbers as
/// Activity Monitor (physical footprint) and derives CPU % from the change in CPU time between two reads.
struct ProcessUsage: Equatable {
    var footprintMB: Double
    var cpuPercent: Double
}

@MainActor
final class ProcessUsageSampler {
    private var lastCPU: Double?
    private var lastWall: Date?

    /// Physical footprint in bytes.
    nonisolated static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    /// Total CPU seconds (user + system) used by the process so far, across all threads.
    nonisolated static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// The footprint now and the CPU % (of one core) since the previous call; the first call reports 0.
    func sample(now: Date = Date()) -> ProcessUsage {
        let cpu = Self.cpuSeconds()
        var percent = 0.0
        if let lastCPU, let lastWall, now > lastWall {
            percent = max(0, (cpu - lastCPU) / now.timeIntervalSince(lastWall) * 100)
        }
        lastCPU = cpu
        lastWall = now
        return ProcessUsage(footprintMB: Double(Self.footprintBytes()) / 1_048_576, cpuPercent: percent)
    }
}
