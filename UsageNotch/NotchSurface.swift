import AppKit
import Observation
import QuartzCore

@MainActor @Observable
final class NotchPresentation {
    var expanded = false
    var pinned = false
    var animates = false
    var showsLaunchMark = false
    var updateVersion: String?
}

/// Keeps the hosting view at its final layout size while Core Animation morphs the visible outline.
@MainActor
final class NotchSurface: NSView {
    private let backdrop = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let silhouetteMask = CAShapeLayer()
    private let clippedContent = NSView()
    private let animationKey = "notch-shape"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clippedContent.wantsLayer = true
        clippedContent.autoresizingMask = [.width, .height]
        clippedContent.frame = bounds
        layer?.addSublayer(backdrop)
        addSubview(clippedContent)
        layer?.addSublayer(outline)

        backdrop.fillColor = NSColor.black.cgColor
        backdrop.shadowColor = NSColor.black.cgColor
        backdrop.shadowRadius = 35
        backdrop.shadowOffset = CGSize(width: 0, height: -28)
        outline.fillColor = nil
        outline.strokeColor = NSColor.white.withAlphaComponent(0.05).cgColor
        outline.lineWidth = 1
        outline.zPosition = 1
        silhouetteMask.fillColor = NSColor.black.cgColor
        clippedContent.layer?.mask = silhouetteMask
    }

    required init?(coder: NSCoder) { nil }

    func install(_ host: NSView) {
        clippedContent.subviews.forEach { $0.removeFromSuperview() }
        host.frame = clippedContent.bounds
        host.autoresizingMask = [.width, .height]
        clippedContent.addSubview(host)
    }

    var isAnimating: Bool { backdrop.animation(forKey: animationKey) != nil }

    func contains(_ point: NSPoint) -> Bool {
        let path = backdrop.presentation()?.path ?? backdrop.path
        return path?.contains(convert(point, from: nil)) == true
    }

    func show(size: CGSize, style: CompactStyle, expanded: Bool, animated: Bool) {
        let current = backdrop.presentation()
        let previous = current?.path ?? backdrop.path
        let shadow = current?.shadowOpacity ?? backdrop.shadowOpacity
        let border = outline.presentation()?.opacity ?? outline.opacity
        let scale = window?.backingScaleFactor ?? 2

        var transform = CGAffineTransform(
            a: 1, b: 0, c: 0, d: -1,
            tx: (bounds.width - size.width) / 2, ty: bounds.height
        )
        guard let target = NotchShape(style: style, progress: expanded ? 1 : 0)
            .path(in: CGRect(origin: .zero, size: size)).cgPath.copy(using: &transform) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [backdrop, outline, silhouetteMask] {
            layer.removeAllAnimations()
            layer.frame = bounds
            layer.contentsScale = scale
            layer.path = target
        }

        backdrop.shadowPath = target
        backdrop.shadowOpacity = expanded ? 0.55 : 0
        outline.opacity = expanded ? 1 : 0

        if animated, let previous {
            func animate(_ layer: CALayer, _ path: String, from start: Any, to end: Any) {
                let animation: CABasicAnimation
                if expanded {
                    let spring = CASpringAnimation(keyPath: path)
                    spring.mass = 1
                    spring.stiffness = 310
                    spring.damping = 30
                    spring.duration = 0.38
                    animation = spring
                } else {
                    animation = CABasicAnimation(keyPath: path)
                    animation.duration = 0.21
                    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                }
                animation.fromValue = start
                animation.toValue = end
                layer.add(animation, forKey: path == "path" ? animationKey : path)
            }

            for layer in [backdrop, outline, silhouetteMask] {
                animate(layer, "path", from: previous, to: target)
            }
            animate(backdrop, "shadowPath", from: previous, to: target)
            animate(backdrop, "shadowOpacity", from: shadow, to: backdrop.shadowOpacity)
            animate(outline, "opacity", from: border, to: outline.opacity)
        }

        CATransaction.commit()
    }
}
