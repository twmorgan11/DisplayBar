import AppKit

/// A brightness row laid out like the Sound menu's volume slider: small sun, native slider, large sun.
@MainActor
final class BrightnessSliderView: NSView {
    // Points from the menu's left edge for a macOS 26 menu row: icon column centre, title column,
    // and the trailing inset submenu chevrons end at.
    private static let iconCenterX: CGFloat = 31
    private static let titleX: CGFloat = 46
    private static let trailingInset: CGFloat = 18
    private static let spacing: CGFloat = 6
    /// Keep the built-in display from going fully dark, which would hide the menu itself.
    private static let minimumBrightness: Float = 0.02

    private let displayID: CGDirectDisplayID
    private let dimIcon = BrightnessSliderView.icon("sun.min.fill")
    private let brightIcon = BrightnessSliderView.icon("sun.max.fill")
    private let slider: NSSlider

    init(displayID: CGDirectDisplayID, brightness: Float) {
        self.displayID = displayID
        slider = NSSlider(value: Double(brightness), minValue: 0, maxValue: 1, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        autoresizingMask = [.width]  // stretch to the menu's width

        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isContinuous = true
        // Menu bar apps are never the active app, so controls draw in their inactive grey; keep the accent fill like the Sound menu.
        slider.trackFillColor = .controlAccentColor
        slider.setAccessibilityLabel("Brightness")
        [dimIcon, slider, brightIcon].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func icon(_ symbol: String) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        view.contentTintColor = .labelColor
        return view
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Measure from the menu window's edge, so the columns line up even if the menu insets item views.
        let inset = window == nil ? 0 : max(0, convert(NSPoint.zero, to: nil).x)
        let menuWidth = window?.frame.width ?? bounds.width
        let midY = bounds.midY

        dimIcon.frame = CGRect(x: Self.iconCenterX - inset - 10, y: midY - 10, width: 20, height: 20)
        brightIcon.frame = CGRect(x: menuWidth - Self.trailingInset - inset - 20, y: midY - 10, width: 20, height: 20)

        let x = Self.titleX - inset - 2
        let height = slider.intrinsicContentSize.height
        slider.frame = CGRect(x: x, y: midY - height / 2, width: max(60, brightIcon.frame.minX - Self.spacing - x), height: height)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        Brightness.set(max(Float(sender.doubleValue), Self.minimumBrightness), for: displayID)
    }
}
