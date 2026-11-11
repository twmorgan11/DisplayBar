import CoreGraphics

/// Pure geometry for the drag-to-arrange view. All rects are in global display coordinates
/// (points, y grows downward), so this is independent of how the arrangement is drawn.
enum Snapping {
    /// The nearest origin to `origin` where a display of `size` sits flush against an edge of at least one
    /// of `others` (sharing part of that edge) without overlapping any of them. Along the shared edge the
    /// position snaps to start/centre/end alignment when within `threshold`.
    static func snap(origin p: CGPoint, size: CGSize, around others: [CGRect], threshold: CGFloat) -> CGPoint? {
        var best: CGPoint?
        var bestDistance = CGFloat.infinity

        for r in others {
            // Require a little shared edge so the cursor can actually travel between the displays.
            let minOverlapY = min(size.height, r.height) * 0.1
            let minOverlapX = min(size.width, r.width) * 0.1
            var candidates: [CGPoint] = []

            for x in [r.maxX, r.minX - size.width] {  // right of / left of
                let y = clamp(p.y, r.minY - size.height + minOverlapY, r.maxY - minOverlapY)
                candidates.append(CGPoint(x: x, y: align(y, to: [r.minY, r.midY - size.height / 2, r.maxY - size.height], threshold)))
            }
            for y in [r.maxY, r.minY - size.height] {  // below / above
                let x = clamp(p.x, r.minX - size.width + minOverlapX, r.maxX - minOverlapX)
                candidates.append(CGPoint(x: align(x, to: [r.minX, r.midX - size.width / 2, r.maxX - size.width], threshold), y: y))
            }

            for candidate in candidates {
                let c = CGPoint(x: candidate.x.rounded(), y: candidate.y.rounded())
                let rect = CGRect(origin: c, size: size)
                if others.contains(where: { overlaps($0, rect) }) { continue }
                let distance = hypot(c.x - p.x, c.y - p.y)
                if distance < bestDistance {
                    best = c
                    bestDistance = distance
                }
            }
        }
        return best
    }

    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        return !i.isNull && i.width > 0.5 && i.height > 0.5
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), hi)
    }

    private static func align(_ v: CGFloat, to targets: [CGFloat], _ threshold: CGFloat) -> CGFloat {
        let nearest = targets.min { abs($0 - v) < abs($1 - v) }
        if let nearest, abs(nearest - v) <= threshold { return nearest }
        return v
    }
}
