import SwiftUI

/// Shown when tap creation failed — almost always missing the
/// System Audio Recording permission.
struct PermissionBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio access needed")
                    .font(.caption.weight(.semibold))
                Text("Allow Fader to record system audio in Privacy & Security.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") {
                let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
                if let settingsURL = URL(string: url) {
                    NSWorkspace.shared.open(settingsURL)
                }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
