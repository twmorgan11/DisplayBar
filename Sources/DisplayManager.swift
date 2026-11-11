import AppKit
import CoreGraphics
import ImageIO

struct DisplayInfo {
    let id: CGDirectDisplayID
    var name: String
    let isBuiltin: Bool
    var isMain: Bool
    let isMirror: Bool
    /// Bounds in the global display coordinate space (points, origin = top-left of main display, y grows downward).
    var bounds: CGRect
    let currentMode: CGDisplayMode?
}

struct DisplayError: LocalizedError {
    let action: String
    let code: CGError
    var errorDescription: String? { "\(action) failed (CGError \(code.rawValue))." }
}

struct ModeKey: Hashable {
    let width, height, pixelWidth, pixelHeight: Int
}

extension CGDisplayMode {
    var key: ModeKey { ModeKey(width: width, height: height, pixelWidth: pixelWidth, pixelHeight: pixelHeight) }
    var isHiDPI: Bool { pixelWidth > width }
    // IOGraphicsTypes.h: kDisplayModeDefaultFlag
    var isDefaultMode: Bool { ioFlags & 0x0000_0004 != 0 }

    var sizeLabel: String { "\(width) × \(height)" }

    var refreshLabel: String? {
        guard refreshRate > 0 else { return nil }
        if abs(refreshRate - refreshRate.rounded()) < 0.01 { return "\(Int(refreshRate.rounded())) Hz" }
        return String(format: "%.2f Hz", refreshRate)
    }

    func hasSameRefresh(as other: CGDisplayMode) -> Bool { abs(refreshRate - other.refreshRate) < 0.01 }
}

struct ResolutionOptions {
    /// System Settings' thumbnail choices ("Larger Text" … "More Space"), largest first. Empty if unknown.
    var recommended: [CGDisplayMode]
    /// System Settings' "Show all resolutions" list, largest first.
    var all: [CGDisplayMode]
    var defaultKey: ModeKey?
}

@MainActor
enum DisplayManager {

    // MARK: - Querying

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    static func displays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        ids = Array(ids.prefix(Int(count)))

        let mainID = CGMainDisplayID()
        var infos = ids.map { id in
            let builtin = CGDisplayIsBuiltin(id) != 0
            return DisplayInfo(
                id: id,
                name: screen(for: id)?.localizedName ?? (builtin ? "Built-in Display" : "Display \(id)"),
                isBuiltin: builtin,
                isMain: id == mainID,
                isMirror: CGDisplayMirrorsDisplay(id) != 0,
                bounds: CGDisplayBounds(id),
                currentMode: CGDisplayCopyDisplayMode(id)
            )
        }

        // Two identical monitors report the same name; number them so the menu is unambiguous.
        let duplicated = Set(Dictionary(grouping: infos, by: \.name).filter { $0.value.count > 1 }.keys)
        var seen: [String: Int] = [:]
        for i in infos.indices where duplicated.contains(infos[i].name) {
            let base = infos[i].name
            seen[base, default: 0] += 1
            infos[i].name = "\(base) (\(seen[base]!))"
        }

        // External displays first, then left-to-right.
        return infos.sorted {
            if $0.isBuiltin != $1.isBuiltin { return !$0.isBuiltin }
            return $0.bounds.minX < $1.bounds.minX
        }
    }

    /// Every mode the hardware reports, including low-resolution duplicates, so any mode System Settings refers to can be found.
    private static func everyMode(for id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        return modes.filter { $0.isUsableForDesktopGUI() }
    }

    /// The modes System Settings offers in `list`; falls back to the public API's (de-duplicated) list.
    private static func offeredModes(for id: CGDirectDisplayID, list: SystemSettingsModes.List) -> [CGDisplayMode]? {
        if let ids = SystemSettingsModes.modeIDs(for: id, list: list) {
            return everyMode(for: id).filter { ids.contains($0.ioDisplayModeID) }
        }
        guard list == .all else { return nil }
        let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] ?? []
        return modes.filter { $0.isUsableForDesktopGUI() }
    }

    static func resolutionOptions(for display: DisplayInfo) -> ResolutionOptions {
        let modes = offeredModes(for: display.id, list: .all) ?? []
        let all = onePerResolution(modes, current: display.currentMode)
        // Pick the recommended sizes from the full list so the current refresh rate is kept where possible.
        let recommendedKeys = Set((offeredModes(for: display.id, list: .recommended) ?? []).map(\.key))
        return ResolutionOptions(
            recommended: all.filter { recommendedKeys.contains($0.key) },
            all: all,
            defaultKey: modes.first(where: \.isDefaultMode)?.key
        )
    }

    /// One mode per distinct resolution, preferring the current refresh rate, then the highest.
    private static func onePerResolution(_ modes: [CGDisplayMode], current: CGDisplayMode?) -> [CGDisplayMode] {
        func score(_ m: CGDisplayMode) -> (Int, Double) {
            ((current.map { m.hasSameRefresh(as: $0) } ?? false) ? 1 : 0, m.refreshRate)
        }
        var best: [ModeKey: CGDisplayMode] = [:]
        for mode in modes {
            if let existing = best[mode.key], score(existing) >= score(mode) { continue }
            best[mode.key] = mode
        }
        return best.values.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.pixelWidth > $1.pixelWidth
        }
    }

    // MARK: - Wallpaper (for the arrangement view)

    private static var wallpaperCache: [URL: NSImage?] = [:]

    /// Only read wallpapers from places that don't trigger a privacy prompt (unlike Box/iCloud/Desktop/Documents/Downloads).
    private static let wallpaperFolders = ["/System/Library/Desktop Pictures/", "/Library/Desktop Pictures/", NSHomeDirectory() + "/Pictures/"]

    static func wallpaper(for id: CGDirectDisplayID) -> NSImage? {
        guard let screen = screen(for: id), let url = NSWorkspace.shared.desktopImageURL(for: screen),
              wallpaperFolders.contains(where: { url.path.hasPrefix($0) })
        else { return nil }
        if let cached = wallpaperCache[url] { return cached }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ] as CFDictionary
        var image: NSImage?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) {
            image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        }
        wallpaperCache[url] = .some(image)  // cache failures too
        return image
    }

    // MARK: - Applying changes

    static func apply(_ mode: CGDisplayMode, to id: CGDirectDisplayID) throws {
        try configure("Changing display mode") { config in
            CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        }
    }

    /// Sets every display's origin at once. The display at (0,0) is the main one, so origins are shifted to put `mainID` there.
    static func applyArrangement(_ origins: [CGDirectDisplayID: CGPoint], mainID: CGDirectDisplayID) throws {
        guard let anchor = origins[mainID] else { return }
        try configure("Arranging displays") { config in
            for (id, origin) in origins {
                let x = Int32((origin.x - anchor.x).rounded())
                let y = Int32((origin.y - anchor.y).rounded())
                let err = CGConfigureDisplayOrigin(config, id, x, y)
                if err != .success { return err }
            }
            return .success
        }
    }

    private static func configure(_ action: String, _ body: (CGDisplayConfigRef) -> CGError) throws {
        var config: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&config)
        guard err == .success, let config else { throw DisplayError(action: action, code: err) }
        err = body(config)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError(action: action, code: err)
        }
        err = CGCompleteDisplayConfiguration(config, .permanently)
        guard err == .success else { throw DisplayError(action: action, code: err) }
    }

    // MARK: - Diagnostics (`DisplayBar --list`)

    static func printSummary() {
        print("Mode lists: " + (SystemSettingsModes.isAvailable ? "System Settings (MonitorPanel)" : "public API fallback"))
        for d in displays() {
            print("\n\(d.name)  id=\(d.id)\(d.isMain ? "  [main]" : "")\(d.isBuiltin ? "  [built-in]" : "")\(d.isMirror ? "  [mirror]" : "")")
            print("  bounds: \(d.bounds)")
            if let m = d.currentMode {
                print("  current: \(m.sizeLabel) @ \(m.refreshLabel ?? "?")  (\(m.pixelWidth)×\(m.pixelHeight) px)")
            }
            let options = resolutionOptions(for: d)
            func describe(_ modes: [CGDisplayMode]) -> String {
                modes.map { $0.sizeLabel + ($0.key == options.defaultKey ? " (default)" : "") }.joined(separator: ", ")
            }
            print("  recommended (\(options.recommended.count)): \(describe(options.recommended))")
            print("  all (\(options.all.count)): \(describe(options.all))")
            print("  brightness: " + (Brightness.value(for: d.id).map { String(format: "%.0f%%", $0 * 100) } ?? "not controllable"))
            let wallpaperName = screen(for: d.id).flatMap { NSWorkspace.shared.desktopImageURL(for: $0)?.lastPathComponent } ?? "none"
            print("  wallpaper: \(wallpaperName) (thumbnail \(wallpaper(for: d.id) != nil ? "ok" : "unavailable, using colour fill"))")
        }
    }
}
