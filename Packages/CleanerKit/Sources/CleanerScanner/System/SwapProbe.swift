import Darwin

/// Swap file usage from the kernel.
public struct SwapUsage: Sendable, Hashable {
    /// Swap space the system has set up, in bytes.
    public let total: Int64
    /// Swap space in use, in bytes.
    public let used: Int64
    /// Swap space still free, in bytes.
    public let free: Int64

    /// Creates a swap usage value.
    public init(total: Int64, used: Int64, free: Int64) {
        self.total = total
        self.used = used
        self.free = free
    }
}

/// Reads swap usage with `sysctlbyname("vm.swapusage")`. No process is launched.
public enum SwapProbe {
    /// Current swap usage, or `nil` if the kernel does not answer.
    public static func current() -> SwapUsage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return SwapUsage(
            total: Int64(clamping: usage.xsu_total),
            used: Int64(clamping: usage.xsu_used),
            free: Int64(clamping: usage.xsu_avail)
        )
    }
}
