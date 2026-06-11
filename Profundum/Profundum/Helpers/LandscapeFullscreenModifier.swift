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
                        if value.translation.height > 80 {
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
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
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
