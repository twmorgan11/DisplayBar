import CoreGraphics
import Foundation

/// Brightness through DisplayServices.framework (private), the same path the brightness keys use.
/// Supported on the built-in display and Apple displays; most third-party monitors report no support.
@MainActor
enum Brightness {
    private typealias CanChangeFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private struct API {
        let canChange: CanChangeFn
        let get: GetFn
        let set: SetFn
    }

    private static let api: API? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let canChange = dlsym(handle, "DisplayServicesCanChangeBrightness"),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness")
        else { return nil }
        return API(canChange: unsafeBitCast(canChange, to: CanChangeFn.self),
                   get: unsafeBitCast(get, to: GetFn.self),
                   set: unsafeBitCast(set, to: SetFn.self))
    }()

    /// Current brightness (0…1), or nil if this display's brightness can't be controlled.
    static func value(for id: CGDirectDisplayID) -> Float? {
        guard let api, api.canChange(id) else { return nil }
        var value: Float = 0
        return api.get(id, &value) == 0 ? value : nil
    }

    static func set(_ value: Float, for id: CGDirectDisplayID) {
        _ = api?.set(id, min(max(value, 0), 1))
    }
}
