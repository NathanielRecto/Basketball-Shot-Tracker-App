import SwiftUI
import UIKit

/// First screen: the app icon, what the app does, how to set the phone up, and Start (opens the camera).
struct StartView: View {
    let onStart: () -> Void
    let onSessions: () -> Void

    /// The app icon file xtool bundles (xtool.yml iconPath), so the screen and the home screen match.
    private static let icon: UIImage? = Bundle.main.url(forResource: "AppIcon", withExtension: "png")
        .flatMap { UIImage(contentsOfFile: $0.path) }

    var body: some View {
        ZStack {
            Theme.background

            HStack(spacing: 48) {
                VStack(spacing: 14) {
                    if let icon = Self.icon {
                        Image(uiImage: icon)
                            .resizable()
                            .frame(width: 150, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                    }
                    Text("Shot Tracker")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Calls every shot made or missed, live")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                }

                VStack(alignment: .leading, spacing: 18) {
                    tip("camera.on.rectangle", "Phone on a tripod at the sideline, in landscape")
                    tip("viewfinder", "0.5x or 1x zoom (pinch to adjust), with the rim in view the whole time")
                    tip("basketball.fill", "Shoot as usual: the hoop is found by itself")
                    Button(action: onStart) {
                        Label("Start", systemImage: "play.fill")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.orange)
                    .padding(.top, 6)
                    Button(action: onSessions) {
                        Label("Sessions", systemImage: "film.stack")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .frame(maxWidth: 360)
            }
            .foregroundStyle(.white)
            .padding(32)
        }
        .statusBarHidden()
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.body)
        } icon: {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.orange)
                .frame(width: 30)
        }
    }
}

/// Start screen first; the camera screen only while tracking (so the camera is off elsewhere); recorded sessions.
struct RootView: View {
    private enum Screen {
        case start, tracking, sessions
    }

    @State private var screen = Screen.start

    var body: some View {
        switch screen {
        case .start: StartView(onStart: { screen = .tracking }, onSessions: { screen = .sessions })
        case .tracking: LiveView(onClose: { screen = .start })
        case .sessions: SessionsView(onClose: { screen = .start })
        }
    }
}
