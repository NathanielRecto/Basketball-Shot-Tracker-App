import SwiftUI

/// The app's colours, shared by the start and sessions screens (and the icon: scripts/make_icon.py).
enum Theme {
    static let navyTop = Color(red: 13 / 255, green: 24 / 255, blue: 43 / 255)
    static let navyBottom = Color(red: 28 / 255, green: 50 / 255, blue: 82 / 255)
    static let orange = Color(red: 242 / 255, green: 140 / 255, blue: 40 / 255)
    static let row = Color.white.opacity(0.07)

    static var background: some View {
        LinearGradient(colors: [navyTop, navyBottom], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
    }
}

extension View {
    /// Navy background, light text and a navy navigation bar.
    func themed() -> some View {
        background(Theme.background)
            .scrollContentBackground(.hidden)
            .toolbarBackground(Theme.navyTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .preferredColorScheme(.dark)
            .tint(Theme.orange)
    }
}
