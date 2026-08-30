import Foundation
import IOKit.ps

/// A quick read of the Mac's power state — used to warn before and during a long unplugged
/// lecture recording on a laptop.
enum PowerMonitor {

    struct Snapshot {
        /// 0…1 charge, or nil on a desktop / when it can't be read.
        var batteryFraction: Double?
        var isPluggedIn: Bool
        var lowPowerMode: Bool

        var batteryPercent: Int? { batteryFraction.map { Int(($0 * 100).rounded()) } }
    }

    static func snapshot() -> Snapshot {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return Snapshot(batteryFraction: nil, isPluggedIn: true, lowPowerMode: lowPower)
        }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int,
                  max > 0
            else { continue }
            let state = desc[kIOPSPowerSourceStateKey] as? String
            return Snapshot(
                batteryFraction: Double(current) / Double(max),
                isPluggedIn: state == kIOPSACPowerValue,
                lowPowerMode: lowPower
            )
        }

        return Snapshot(batteryFraction: nil, isPluggedIn: true, lowPowerMode: lowPower)
    }
}
