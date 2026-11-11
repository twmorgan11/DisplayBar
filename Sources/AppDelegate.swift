import AppKit
import ServiceManagement

private final class ModeChoice {
    let displayID: CGDirectDisplayID
    let mode: CGDisplayMode
    init(displayID: CGDirectDisplayID, mode: CGDisplayMode) {
        self.displayID = displayID
        self.mode = mode
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private weak var arrangementView: ArrangementView?
    private var refreshScheduled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Displays")
            image?.isTemplate = true
            button.image = image
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        SystemSettingsModes.warmUp()
    }

    // Rebuild every time the menu opens so it always reflects the live configuration.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let displays = DisplayManager.displays()

        let arrangeable = displays.filter { !$0.isMirror }
        if arrangeable.count > 1 {
            menu.addItem(.sectionHeader(title: "Arrangement"))
            let view = ArrangementView(displays: arrangeable) { [weak self] origins, mainID in
                self?.applyArrangement(origins, mainID: mainID) ?? false
            }
            let item = NSMenuItem()
            item.view = view
            menu.addItem(item)
            arrangementView = view
        }

        for display in displays {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: display.name + (display.isMain ? " — Main" : "")))
            menu.addItem(resolutionItem(for: display))
            if let brightness = Brightness.value(for: display.id) {
                let item = NSMenuItem()
                item.view = BrightnessSliderView(displayID: display.id, brightness: brightness)
                menu.addItem(item)
            }
        }

        // Every row gets an icon: macOS 26 reserves an icon column per section, so mixing rows
        // with and without icons (Quit gets one automatically) leaves sections misaligned.
        menu.addItem(.separator())
        menu.addItem(action("Displays Settings…", #selector(openDisplaySettings), symbol: "gearshape"))
        let login = action("Launch at Login", #selector(toggleLaunchAtLogin), symbol: "power")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let quit = NSMenuItem(title: "Quit DisplayBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "xmark.square", accessibilityDescription: nil)
        menu.addItem(quit)
    }

    // MARK: - Menu sections

    /// Mirrors System Settings: the recommended sizes first, the full "Show all resolutions" list in a submenu.
    private func resolutionItem(for display: DisplayInfo) -> NSMenuItem {
        let current = display.currentMode
        let options = DisplayManager.resolutionOptions(for: display)
        let item = NSMenuItem(title: "Resolution: \(current?.sizeLabel ?? "Unknown")", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "aspectratio", accessibilityDescription: nil)
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let recommended = options.recommended
        for (index, mode) in recommended.enumerated() {
            var label = mode.sizeLabel
            if mode.key == options.defaultKey {
                label += "  — Default"
            } else if recommended.count > 1 && index == 0 {
                label += "  — More Space"
            } else if recommended.count > 1 && index == recommended.count - 1 {
                label += "  — Larger Text"
            }
            submenu.addItem(modeItem(label, display: display, mode: mode, checked: current?.key == mode.key))
        }

        let allMenu: NSMenu
        if recommended.isEmpty {
            allMenu = submenu  // no curated list available: show the full list directly
        } else {
            submenu.addItem(.separator())
            allMenu = NSMenu()
            allMenu.autoenablesItems = false
            let allItem = NSMenuItem(title: "All Resolutions", action: nil, keyEquivalent: "")
            if let current, !recommended.contains(where: { $0.key == current.key }) { allItem.state = .on }
            allItem.submenu = allMenu
            submenu.addItem(allItem)
        }
        for mode in options.all {
            let label = mode.sizeLabel + (mode.key == options.defaultKey ? "  (Default)" : "")
            allMenu.addItem(modeItem(label, display: display, mode: mode, checked: current?.key == mode.key))
        }

        item.submenu = submenu
        return item
    }

    private func modeItem(_ title: String, display: DisplayInfo, mode: CGDisplayMode, checked: Bool) -> NSMenuItem {
        let item = action(title, #selector(selectMode(_:)))
        item.representedObject = ModeChoice(displayID: display.id, mode: mode)
        item.state = checked ? .on : .off
        return item
    }

    // MARK: - Actions

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ModeChoice else { return }
        do {
            try DisplayManager.apply(choice.mode, to: choice.displayID)
        } catch {
            showError(error)
        }
    }

    private func applyArrangement(_ origins: [CGDirectDisplayID: CGPoint], mainID: CGDirectDisplayID) -> Bool {
        do {
            try DisplayManager.applyArrangement(origins, mainID: mainID)
            scheduleRefresh()
            return true
        } catch {
            showError(error)
            return false
        }
    }

    /// Re-reads the real configuration shortly after a drag (macOS may nudge positions) and refreshes the open menu.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self else { return }
            self.refreshScheduled = false
            if self.arrangementView?.isTracking == true {
                self.scheduleRefresh()
            } else {
                self.rebuildMenu()
            }
        }
    }

    @objc private func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            showError(error)
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    // MARK: - Helpers

    private func action(_ title: String, _ selector: Selector, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        return item
    }

    private func showError(_ error: Error) {
        let message = error.localizedDescription
        menu.cancelTracking()  // errors can arrive from the arrangement view while the menu is open
        Task { @MainActor in
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "DisplayBar"
            alert.informativeText = message
            alert.runModal()
        }
    }
}
