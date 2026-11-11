import AppKit

/// A miniature of the display arrangement, like System Settings › Displays › Arrange.
/// Drag a display to move it (it snaps flush against its neighbours); drag the white menu bar
/// onto another display to make that one the main display. Changes apply on mouse-up.
@MainActor
final class ArrangementView: NSView {
    typealias ApplyHandler = @MainActor (_ origins: [CGDirectDisplayID: CGPoint], _ mainID: CGDirectDisplayID) -> Bool

    private static let width: CGFloat = 320
    private static let inset = NSEdgeInsets(top: 6, left: 14, bottom: 22, right: 14)  // bottom leaves room for the hint
    private static let fill: CGFloat = 0.7  // share of the area the arrangement occupies, leaving room to drag

    private var displays: [DisplayInfo]
    private let onApply: ApplyHandler

    // view point = (global point - unionOrigin) * scale + offset
    private var scale: CGFloat = 1
    private var unionOrigin = CGPoint.zero
    private var offset = CGPoint.zero

    private enum Drag {
        case display(id: CGDirectDisplayID, origin: CGPoint, landing: CGPoint?)
        case menuBar(location: CGPoint, target: CGDirectDisplayID?)
    }
    private var drag: Drag?
    private(set) var isTracking = false

    override var isFlipped: Bool { true }  // same orientation as CoreGraphics' global display space

    init(displays: [DisplayInfo], onApply: @escaping ApplyHandler) {
        self.displays = displays
        self.onApply = onApply
        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize(for: displays)))
        autoresizingMask = [.width]  // stretch to the menu's width; the drawing re-centres
        updateTransform()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTransform()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Geometry

    private static func union(of displays: [DisplayInfo]) -> CGRect {
        displays.reduce(CGRect.null) { $0.union($1.bounds) }
    }

    private static func preferredSize(for displays: [DisplayInfo]) -> CGSize {
        let u = union(of: displays)
        let areaWidth = width - inset.left - inset.right
        let s = areaWidth * fill / max(u.width, 1)
        let areaHeight = min(max(u.height * s / fill, 110), 220)
        return CGSize(width: width, height: areaHeight + inset.top + inset.bottom)
    }

    private var area: CGRect {
        CGRect(x: Self.inset.left, y: Self.inset.top,
               width: bounds.width - Self.inset.left - Self.inset.right,
               height: bounds.height - Self.inset.top - Self.inset.bottom)
    }

    private func updateTransform() {
        let u = Self.union(of: displays)
        guard !u.isNull, u.width > 0, u.height > 0 else { return }
        let a = area
        scale = min(a.width * Self.fill / u.width, a.height * Self.fill / u.height)
        unionOrigin = u.origin
        offset = CGPoint(x: a.midX - u.width * scale / 2, y: a.midY - u.height * scale / 2)
    }

    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: (r.minX - unionOrigin.x) * scale + offset.x,
               y: (r.minY - unionOrigin.y) * scale + offset.y,
               width: r.width * scale, height: r.height * scale)
    }

    private func menuBarRect(in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(3, min(6, rect.height * 0.07)))
    }

    private func displayInfo(at point: CGPoint) -> DisplayInfo? {
        displays.last { viewRect($0.bounds).contains(point) }
    }

    private var currentOrigins: [CGDirectDisplayID: CGPoint] {
        Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.bounds.origin) })
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        if let main = displays.first(where: \.isMain),
           menuBarRect(in: viewRect(main.bounds)).insetBy(dx: 0, dy: -3).contains(start) {
            trackMenuBar(currentMain: main.id)
        } else if let target = displayInfo(at: start) {
            trackDisplay(target, from: start)
        }
    }

    /// Local tracking loop: handles the whole drag here, which also works while the menu is tracking events.
    private func trackMouse(_ handle: (_ location: CGPoint) -> Void) {
        isTracking = true
        defer { isTracking = false; drag = nil; needsDisplay = true }
        while let event = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            handle(convert(event.locationInWindow, from: nil))
            if event.type == .leftMouseUp { break }
            display()
        }
    }

    private func trackDisplay(_ target: DisplayInfo, from start: CGPoint) {
        let others = displays.filter { $0.id != target.id }.map(\.bounds)
        var landing: CGPoint?
        var moved = false

        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        trackMouse { location in
            if hypot(location.x - start.x, location.y - start.y) > 3 { moved = true }
            let free = CGPoint(x: target.bounds.minX + (location.x - start.x) / scale,
                               y: target.bounds.minY + (location.y - start.y) / scale)
            landing = Snapping.snap(origin: free, size: target.bounds.size, around: others, threshold: 8 / scale)
            drag = .display(id: target.id, origin: free, landing: landing)
        }

        guard moved, let landing, landing != target.bounds.origin else { return }
        var origins = currentOrigins
        origins[target.id] = landing
        commit(origins, mainID: displays.first(where: \.isMain)?.id ?? target.id)
    }

    private func trackMenuBar(currentMain: CGDirectDisplayID) {
        var target: CGDirectDisplayID?
        trackMouse { location in
            target = displayInfo(at: location)?.id
            drag = .menuBar(location: location, target: target)
        }
        if let target, target != currentMain {
            commit(currentOrigins, mainID: target)
        }
    }

    private func commit(_ origins: [CGDirectDisplayID: CGPoint], mainID: CGDirectDisplayID) {
        guard onApply(origins, mainID), let anchor = origins[mainID] else { return }
        // Show the result straight away (normalised so the main display sits at 0,0) while macOS reconfigures.
        for i in displays.indices {
            let o = origins[displays[i].id] ?? displays[i].bounds.origin
            displays[i].bounds.origin = CGPoint(x: o.x - anchor.x, y: o.y - anchor.y)
            displays[i].isMain = displays[i].id == mainID
        }
        updateTransform()
        needsDisplay = true
    }

    // MARK: - Drawing

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override func draw(_ dirtyRect: NSRect) {
        var draggedID: CGDirectDisplayID?
        var menuBarTarget: CGDirectDisplayID?
        var movingMenuBar = false
        switch drag {
        case let .display(id, _, _): draggedID = id
        case let .menuBar(_, target): movingMenuBar = true; menuBarTarget = target
        case nil: break
        }

        for d in displays where d.id != draggedID {
            drawTile(d, in: viewRect(d.bounds), showMenuBar: d.isMain && !movingMenuBar,
                     highlighted: movingMenuBar && menuBarTarget == d.id)
        }

        if case let .display(id, origin, landing) = drag, let d = displays.first(where: { $0.id == id }) {
            if let landing { drawLandingOutline(viewRect(CGRect(origin: landing, size: d.bounds.size))) }
            drawTile(d, in: viewRect(CGRect(origin: origin, size: d.bounds.size)),
                     showMenuBar: d.isMain, highlighted: true, lifted: true)
        }

        if case let .menuBar(location, _) = drag, let main = displays.first(where: \.isMain) {
            drawFloatingMenuBar(at: location, width: viewRect(main.bounds).width)
        }

        drawHint()
    }

    private func cornerRadius(for rect: CGRect) -> CGFloat {
        min(8, max(3, min(rect.width, rect.height) * 0.08))
    }

    /// A frosted-glass tile: soft shadow, translucent body that's brighter at the top, a sheen, and a light-catching rim.
    private func drawTile(_ d: DisplayInfo, in rect: CGRect, showMenuBar: Bool, highlighted: Bool, lifted: Bool = false) {
        let dark = isDark
        let radius = cornerRadius(for: rect)
        let body = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let wallpaper = DisplayManager.wallpaper(for: d.id)

        // Shadow, cast by a faint frosted base layer.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(lifted ? 0.30 : 0.16)
        shadow.shadowBlurRadius = lifted ? 14 : 6
        shadow.shadowOffset = NSSize(width: 0, height: lifted ? -5 : -2)
        shadow.set()
        NSColor.white.withAlphaComponent(dark ? 0.10 : 0.30).setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        if let wallpaper {
            wallpaper.draw(in: aspectFill(wallpaper.size, in: rect), from: .zero, operation: .sourceOver,
                           fraction: 1, respectFlipped: true, hints: nil)
        }
        // Frosted body (top → bottom; the view is flipped, so 90° runs downwards).
        let bodyTop = NSColor.white.withAlphaComponent(wallpaper != nil ? 0.16 : (dark ? 0.18 : 0.50))
        let bodyBottom = NSColor.white.withAlphaComponent(wallpaper != nil ? 0.02 : (dark ? 0.05 : 0.18))
        NSGradient(starting: bodyTop, ending: bodyBottom)?.draw(in: rect, angle: 90)
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            rect.fill(using: .sourceOver)
        }
        // Sheen across the top half.
        let sheen = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.5)
        NSGradient(starting: NSColor.white.withAlphaComponent(dark ? 0.12 : 0.35),
                   ending: NSColor.white.withAlphaComponent(0))?.draw(in: sheen, angle: 90)
        if showMenuBar {
            NSColor.white.withAlphaComponent(dark ? 0.70 : 0.92).setFill()
            menuBarRect(in: rect).fill(using: .sourceOver)
        }
        NSGraphicsContext.restoreGraphicsState()

        // Rim: a 1pt edge that catches light at the top and fades towards the bottom.
        NSGraphicsContext.saveGraphicsState()
        let rim = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        rim.append(NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: max(0, radius - 1), yRadius: max(0, radius - 1)))
        rim.windingRule = .evenOdd
        rim.addClip()
        NSGradient(starting: NSColor.white.withAlphaComponent(dark ? 0.45 : 0.95),
                   ending: NSColor.white.withAlphaComponent(dark ? 0.10 : 0.35))?.draw(in: rect, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        // Outer edge for definition against the menu background.
        if highlighted {
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: radius + 1, yRadius: radius + 1)
            ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        } else {
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: -0.25, dy: -0.25), xRadius: radius, yRadius: radius)
            edge.lineWidth = 0.5
            NSColor.black.withAlphaComponent(dark ? 0.45 : 0.14).setStroke()
            edge.stroke()
        }

        let topInset = showMenuBar ? menuBarRect(in: rect).height : 0
        drawLabels(for: d, in: rect, topInset: topInset, overImage: wallpaper != nil)
    }

    /// Display name (up to two lines) with the current resolution underneath, centred in the tile.
    private func drawLabels(for d: DisplayInfo, in rect: CGRect, topInset: CGFloat, overImage: Bool) {
        let box = CGRect(x: rect.minX + 6, y: rect.minY + topInset + 3,
                         width: rect.width - 12, height: rect.height - topInset - 6)
        guard box.width > 12, box.height > 8 else { return }

        let nameSize = min(12, max(9, rect.height * 0.12))
        var nameAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: nameSize, weight: .semibold),
            .foregroundColor: overImage ? NSColor.white : NSColor.labelColor,
            .paragraphStyle: Self.centeredWrapping,
        ]
        var detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: nameSize - 1.5, weight: .regular),
            .foregroundColor: overImage ? NSColor.white.withAlphaComponent(0.85) : NSColor.secondaryLabelColor,
            .paragraphStyle: Self.centeredTruncating,
        ]
        if overImage {  // keep text legible over a wallpaper
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = .zero
            nameAttributes[.shadow] = shadow
            detailAttributes[.shadow] = shadow
        }

        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        let name = NSAttributedString(string: d.name, attributes: nameAttributes)
        let lineHeight = name.size().height
        let maxNameHeight = min(lineHeight * 2, box.height)
        let nameHeight = min(name.boundingRect(with: CGSize(width: box.width, height: maxNameHeight), options: options).height,
                             maxNameHeight)

        let detail = d.currentMode.map { NSAttributedString(string: $0.sizeLabel, attributes: detailAttributes) }
        let detailHeight = detail?.size().height ?? 0
        let gap: CGFloat = 1
        let showDetail = detail != nil && nameHeight + gap + detailHeight <= box.height

        var y = box.midY - (nameHeight + (showDetail ? gap + detailHeight : 0)) / 2
        name.draw(with: CGRect(x: box.minX, y: y, width: box.width, height: nameHeight), options: options)
        if showDetail, let detail {
            y += nameHeight + gap
            detail.draw(with: CGRect(x: box.minX, y: y, width: box.width, height: detailHeight), options: options)
        }
    }

    private func drawLandingOutline(_ rect: CGRect) {
        let radius = cornerRadius(for: rect)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: radius, yRadius: radius)
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        path.fill()
        path.lineWidth = 1.5
        path.setLineDash([5, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }

    private func drawFloatingMenuBar(at location: CGPoint, width: CGFloat) {
        let rect = CGRect(x: location.x - width / 2, y: location.y - 3, width: width, height: 6)
        let bar = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        bar.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHint() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: Self.centeredTruncating,
        ]
        let text = "Drag to arrange · drag the menu bar to set main" as NSString
        let height = text.size(withAttributes: attributes).height
        let y = bounds.height - Self.inset.bottom + (Self.inset.bottom - height) / 2
        text.draw(in: CGRect(x: 0, y: y, width: bounds.width, height: height), withAttributes: attributes)
    }

    private static let centeredTruncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    private static let centeredWrapping: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        return style
    }()

    private func aspectFill(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let s = max(rect.width / size.width, rect.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}
