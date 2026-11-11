import Foundation
import CoreGraphics

// Minimal views onto MonitorPanel.framework, the private framework behind System Settings › Displays.
// Messages are sent via these @objc protocols; every selector is checked with responds(to:) first.
@objc private protocol MPDisplayMgr {
    @objc(displayWithID:) func display(withID id: Int32) -> AnyObject?
}

@objc private protocol MPDisplay {
    @objc(modesOfType:) func modes(ofType type: UInt) -> [AnyObject]?
}

@objc private protocol MPDisplayMode {
    @objc var modeNumber: Int32 { get }  // equals CGDisplayMode.ioDisplayModeID
}

/// Which display modes System Settings offers, so the menu shows the same choices instead of every mode the hardware reports.
@MainActor
enum SystemSettingsModes {
    enum List: UInt {
        /// The handful shown as thumbnails, from "Larger Text" to "More Space".
        case recommended = 0
        /// The "Show all resolutions" list (excludes low-resolution duplicates).
        case all = 1
    }

    private static let manager: NSObject? = {
        let path = "/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel"
        let shared = NSSelectorFromString("sharedMgr")
        guard dlopen(path, RTLD_LAZY) != nil,
              let cls = NSClassFromString("MPDisplayMgr") as? NSObject.Type,
              cls.responds(to: shared),
              let mgr = cls.perform(shared)?.takeUnretainedValue() as? NSObject,
              mgr.responds(to: NSSelectorFromString("displayWithID:"))
        else { return nil }
        return mgr
    }()

    static var isAvailable: Bool { manager != nil }

    /// Load the framework ahead of the first menu open.
    static func warmUp() { _ = manager }

    /// `ioDisplayModeID`s System Settings offers for the display, or nil if that can't be determined.
    static func modeIDs(for displayID: CGDirectDisplayID, list: List) -> Set<Int32>? {
        guard let manager,
              let display = unsafeBitCast(manager, to: MPDisplayMgr.self).display(withID: Int32(bitPattern: displayID)) as? NSObject,
              display.responds(to: NSSelectorFromString("modesOfType:"))
        else { return nil }

        let modes = unsafeBitCast(display, to: MPDisplay.self).modes(ofType: list.rawValue) ?? []
        let ids = modes.compactMap { mode -> Int32? in
            guard let mode = mode as? NSObject, mode.responds(to: NSSelectorFromString("modeNumber")) else { return nil }
            return unsafeBitCast(mode, to: MPDisplayMode.self).modeNumber
        }
        return ids.isEmpty ? nil : Set(ids)
    }
}
