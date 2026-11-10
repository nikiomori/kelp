import DesignKit
import SwiftUI

/// Settings' picture of each "Show agents above the Dock" choice: the bottom of a screen, the Dock, and over it the
/// strip with a question (when needed) or every agent's dot (always).
struct DockStripPicture: View {
    let option: String

    var body: some View {
        VStack(spacing: 4) {
            Spacer()
            if option != "off" {
                HStack(spacing: 3) {
                    if option == "needed" {
                        Circle().fill(Color.textOrange).frame(width: 5, height: 5)
                        Capsule().fill(.white.opacity(0.8)).frame(width: 30, height: 3)
                    } else {
                        ForEach([Color.textGreen, .textGreen, .textOrange], id: \.self) {
                            Circle().fill($0).frame(width: 5, height: 5)
                        }
                    }
                }
                .padding(.horizontal, 6).frame(height: 13)
                .background(
                    Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: Metrics.radiusXS, style: .continuous))
            }
            RoundedRectangle(cornerRadius: Metrics.radiusXS, style: .continuous).fill(Color.primary.opacity(0.18))
                .frame(height: 9).padding(.horizontal, 18)
        }
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.12)], startPoint: .top,
                endPoint: .bottom))
    }
}

/// Settings' picture of each "Dock icon" choice: Kelp's icon as the Dock shows it, plain, with its agents as pills at its
/// foot, or with the plan's ring.
struct DockIconPicture: View {
    let option: String

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 38, height: 38)
            .overlay(alignment: .bottom) {
                if option == "agents" {
                    HStack(spacing: 2) {
                        ForEach([Color.textGreen, .textOrange, .textGreen], id: \.self) {
                            Capsule().fill($0).frame(width: 7, height: 4)
                        }
                    }
                    .offset(y: 4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if option == "usage" {
                    Circle().trim(from: 0, to: 0.62).stroke(
                        Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90)).frame(width: 13, height: 13)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 17, height: 17))
                    .offset(x: 3, y: 3)
                }
            }
    }
}
