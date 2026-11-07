import CleanerCore
import CleanerScanner
import Foundation

/// `tcbench volume`: prints what the system probes see on this Mac. Read-only.
enum VolumeCommand {
    static func run() async {
        let clock = ContinuousClock()
        let started = clock.now

        async let volumeTask = VolumeInfo.current()
        async let snapshotsTask = Snapshots.list()
        async let devicesTask = Simulators.devices()
        async let runtimesTask = Simulators.runtimes()
        let (volume, snapshots, devices, runtimes) = await (volumeTask, snapshotsTask, devicesTask, runtimesTask)
        let swap = SwapProbe.current()
        let elapsed = started.duration(to: clock.now)

        print("== Volume (startup container) ==")
        print("total                      \(size(volume.total))")
        print("available                  \(size(volume.available))")
        print("available (important)      \(size(volume.availableForImportantUsage))")
        print("available (opportunistic)  \(size(volume.availableForOpportunisticUsage))")
        print("purgeable                  \(size(volume.purgeable))")
        print("container used             \(size(volume.containerUsed))")
        print("Data volume used           \(volume.dataVolumeUsed.map(size) ?? "unknown")")
        if volume.volumes.isEmpty {
            print("APFS volumes               unknown")
        } else {
            for item in volume.volumes {
                let roles = item.roles.isEmpty ? "-" : item.roles.joined(separator: ",")
                print("  \(item.name) [\(roles)]  \(size(item.bytesUsed))")
            }
        }

        print("\n== Local snapshots ==")
        switch snapshots {
        case .success(let list):
            print("count \(list.count)")
            for snapshot in list {
                let kind = snapshot.isTimeMachine ? "Time Machine" : "other"
                let date = snapshot.date.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "no date"
                print("  \(snapshot.name)  (\(kind), \(date))")
            }
        case .failure(let error):
            print("unknown: \(error)")
        }

        print("\n== Swap ==")
        if let swap {
            print("total \(size(swap.total)), used \(size(swap.used)), free \(size(swap.free))")
        } else {
            print("unknown")
        }

        print("\n== Simulators ==")
        switch devices {
        case .success(let list):
            let available = list.filter(\.isAvailable).count
            let booted = list.filter { $0.state == "Booted" }.count
            print("devices \(list.count) (available \(available), booted \(booted))")
        case .failure(let error):
            print("devices unknown: \(error)")
        }
        switch runtimes {
        case .success(let list):
            let total = list.compactMap(\.sizeBytes).reduce(0, +)
            print("runtimes \(list.count), \(size(total)) on disk")
            for runtime in list {
                print("  \(runtime.name)  \(runtime.sizeBytes.map(size) ?? "size unknown")")
            }
        case .failure(let error):
            print("runtimes unknown: \(error)")
        }

        print("\nprobes took \(elapsed)")
    }

    private static func size(_ bytes: Int64) -> String {
        "\(ByteFormatter.string(bytes)) (\(bytes) bytes)"
    }
}
