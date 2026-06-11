import SwiftUI

#if os(iOS)
/// Locks the view to landscape while presented and restores portrait +
/// free rotation on dismissal. Also adds a downward swipe-to-dismiss
/// gesture, since `fullScreenCover` has no built-in interactive dismissal.
///
/// UIKit caches the result of `supportedInterfaceOrientationsFor`, so
/// resetting `AppDelegate.orientationLock` alone is never picked up —
/// `setNeedsUpdateOfSupportedInterfaceOrientations()` must be called for
/// the change to take effect (otherwise rotation stays stuck in landscape).
struct LandscapeFullscreenModifier: ViewModifier {
    /// Called before dismissing via the swipe gesture (e.g. to pause a timer).
    var onSwipeDismiss: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            // Child gestures (chart scrub, sliders) take precedence over
            // this parent gesture.
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        // Dominant-axis check: a diagonal chart scrub can exceed
                        // 80pt vertically; only dismiss on a clearly downward swipe.
                        let translation = value.translation
                        if translation.height > 80, translation.height > abs(translation.width) {
                            onSwipeDismiss?()
                            dismiss()
                        }
                    }
            )
            .onAppear {
                AppDelegate.orientationLock = .landscape
                Self.requestOrientation(.landscape)
            }
            .onDisappear {
                AppDelegate.orientationLock = .all
                Self.requestOrientation(.portrait)
            }
    }

    static func requestOrientation(_ orientations: UIInterfaceOrientationMask) {
        // Prefer the foreground-active scene: `connectedScenes.first` can be a
        // background or wrong scene under iPad multitasking / Stage Manager.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let windowScene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first else { return }
        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
        windowScene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
#endif

extension View {
    /// Landscape lock + swipe-to-dismiss for fullscreen chart views (iOS only;
    /// no-op on macOS).
    func landscapeFullscreen(onSwipeDismiss: (() -> Void)? = nil) -> some View {
        #if os(iOS)
        modifier(LandscapeFullscreenModifier(onSwipeDismiss: onSwipeDismiss))
        #else
        self
        #endif
    }
}
