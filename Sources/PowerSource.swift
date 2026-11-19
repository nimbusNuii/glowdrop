import Foundation
import IOKit.ps

extension Notification.Name {
    static let powerSourceChanged = Notification.Name("Glowdrop.powerSourceChanged")
}

enum PowerSource {
    /// False on Macs without a battery or when the state cannot be read.
    static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    /// Posts `.powerSourceChanged` on the main run loop whenever the power source changes.
    @MainActor static func startMonitoring() {
        // A C callback cannot capture context, so it only posts a notification.
        let callback: IOPowerSourceCallbackType = { _ in
            NotificationCenter.default.post(name: .powerSourceChanged, object: nil)
        }
        // shortcut: without a source the battery rule keeps the launch-time state; poll if this ever fails.
        guard let source = IOPSCreateLimitedPowerNotification(callback, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
}
