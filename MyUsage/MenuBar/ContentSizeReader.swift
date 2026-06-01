import SwiftUI

extension View {
    /// Reports this view's laid-out size whenever it changes. Uses a
    /// `GeometryReader` background (macOS 14-compatible) rather than
    /// `onGeometryChange` (macOS 15+), so the hosting panel can resize its
    /// window to match the content exactly — growing *and* shrinking.
    func onSizeChange(_ action: @escaping (CGSize) -> Void) -> some View {
        background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { action(geometry.size) }
                    .onChange(of: geometry.size) { _, newValue in action(newValue) }
            }
        )
    }
}
