import SwiftUI

/// Bottom row announcing an update. A staged download offers a restart into
/// the new version; an update that is merely available hands off to
/// Sparkle's standard flow (see UpdateController).
struct UpdateBanner: View {
    @Environment(UpdateController.self) private var updater
    let version: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
            Text(updater.stagedVersion != nil
                ? "Fader \(version) is ready to install"
                : "Fader \(version) is available")
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            Button(updater.stagedVersion != nil ? "Restart" : "Update") {
                updater.checkForUpdates()
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
