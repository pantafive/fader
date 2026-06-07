import SwiftUI

/// Bottom row announcing a found update. A dmg install hands off to
/// Sparkle's standard flow; a Homebrew install shows the upgrade command
/// with a copy button instead (see UpdateController for why).
struct UpdateBanner: View {
    @Environment(UpdateController.self) private var updater
    let version: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Fader \(version) is available")
                    .font(.system(size: 11, weight: .semibold))
                if updater.isHomebrewInstall {
                    Text(UpdateController.homebrewCommand)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if updater.isHomebrewInstall {
                Button {
                    UpdateController.copyHomebrewCommand()
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
                .help("Copy the upgrade command")
            } else {
                Button("Update") {
                    updater.checkForUpdates()
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
