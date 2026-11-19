import Foundation
import IOKit.ps

/// Why a model on this Mac isn't asked now: the Mac saves power or runs hot, and agents and builds come first.
enum SuggestionPause: Equatable {
    case lowPower, hot

    /// What the status bar says instead of the model's name.
    var title: String {
        switch self {
        case .lowPower: String(localized: "Paused: Low Power")
        case .hot: String(localized: "Paused: Mac Is Hot")
        }
    }

    /// The card's line on why, and when it comes back.
    var reason: String {
        switch self {
        case .lowPower: String(localized: "Paused while Low Power Mode is on.")
        case .hot: String(localized: "Paused until the Mac cools down.")
        }
    }

    static func of(lowPower: Bool, thermal: ProcessInfo.ThermalState) -> SuggestionPause? {
        if lowPower { return .lowPower }
        return thermal == .serious || thermal == .critical ? .hot : nil
    }

    static var now: SuggestionPause? {
        of(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
    }

    /// Whether the Mac runs on its battery now: then typing pauses longer before a model is asked, so it's asked less.
    static var onBattery: Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        return IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? == kIOPSBatteryPowerValue
    }
}
