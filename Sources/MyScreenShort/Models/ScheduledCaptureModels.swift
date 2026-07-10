import AppKit

struct ScheduledCaptureRegion: Equatable {
    let displayID: CGDirectDisplayID
    let rect: CGRect

    var screen: NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    var isAvailable: Bool {
        guard let screen else { return false }
        return !rect.intersection(CGRect(origin: .zero, size: screen.frame.size)).isNull
    }
}

struct ScheduledCaptureSelection: Equatable {
    let region: ScheduledCaptureRegion
    let delay: Int
}

final class ScheduledCaptureRegionStore {
    static let shared = ScheduledCaptureRegionStore()

    private enum Key {
        static let displayID = "scheduledCapture.displayID"
        static let minX = "scheduledCapture.minX"
        static let minY = "scheduledCapture.minY"
        static let width = "scheduledCapture.width"
        static let height = "scheduledCapture.height"
        static let hasRegion = "scheduledCapture.hasRegion"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ScheduledCaptureRegion? {
        guard defaults.bool(forKey: Key.hasRegion) else { return nil }
        let region = ScheduledCaptureRegion(
            displayID: CGDirectDisplayID(defaults.integer(forKey: Key.displayID)),
            rect: CGRect(
                x: defaults.double(forKey: Key.minX),
                y: defaults.double(forKey: Key.minY),
                width: defaults.double(forKey: Key.width),
                height: defaults.double(forKey: Key.height)
            )
        )
        return region.isAvailable ? region : nil
    }

    func save(_ region: ScheduledCaptureRegion) {
        defaults.set(true, forKey: Key.hasRegion)
        defaults.set(Int(region.displayID), forKey: Key.displayID)
        defaults.set(Double(region.rect.minX), forKey: Key.minX)
        defaults.set(Double(region.rect.minY), forKey: Key.minY)
        defaults.set(Double(region.rect.width), forKey: Key.width)
        defaults.set(Double(region.rect.height), forKey: Key.height)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
