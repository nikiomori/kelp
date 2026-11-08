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
