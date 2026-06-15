import AVKit
import UIKit

final class AccessibleAirPlayRoutePickerView: AVRoutePickerView {
    private var routeName = "Route"

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureRoutePicker()
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        fatalError("AccessibleAirPlayRoutePickerView does not support Interface Builder.")
    }

    func update(routeName: String) {
        guard self.routeName != routeName else { return }
        self.routeName = routeName
        configureAccessibility()
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        configureInternalAccessibility()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // AVKit can reapply route-picker glyph tint during internal layout updates.
        tintColor = .clear
        activeTintColor = .clear
        configureInternalAccessibility()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Treat the full SwiftUI utility tile as the AVRoutePickerView hit target.
        bounds.contains(point)
    }

    override func accessibilityActivate() -> Bool {
        layoutIfNeeded()
        guard let control = firstControl(in: self) else {
            return super.accessibilityActivate()
        }

        control.sendActions(for: .touchDown)
        control.sendActions(for: .touchUpInside)
        control.sendActions(for: .primaryActionTriggered)
        return true
    }

    private func configureRoutePicker() {
        prioritizesVideoDevices = false
        tintColor = .clear
        activeTintColor = .clear
        backgroundColor = .clear
        isUserInteractionEnabled = true
    }

    private func configureAccessibility() {
        // AVKit exposes its inner UIControl separately, so make that real control the accessible button.
        isAccessibilityElement = false
        accessibilityElements = nil
        configureInternalAccessibility()
    }

    private func configureInternalAccessibility() {
        stretchInteractiveSubviews(in: self)
        guard let control = firstControl(in: self) else { return }

        control.isAccessibilityElement = true
        control.accessibilityElements = []
        control.accessibilityElementsHidden = false
        control.accessibilityTraits = [.button]
        control.accessibilityLabel = "AirPlay"
        control.accessibilityValue = routeName
        control.accessibilityHint = "Choose an audio route"
    }

    private func stretchInteractiveSubviews(in view: UIView) {
        for subview in view.subviews {
            subview.frame = view.bounds
            subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            subview.isAccessibilityElement = false
            subview.accessibilityElements = []
            subview.accessibilityElementsHidden = false
            stretchInteractiveSubviews(in: subview)
        }
    }

    private func firstControl(in view: UIView) -> UIControl? {
        if view !== self, let control = view as? UIControl {
            return control
        }

        for subview in view.subviews {
            if let control = firstControl(in: subview) {
                return control
            }
        }

        return nil
    }
}
