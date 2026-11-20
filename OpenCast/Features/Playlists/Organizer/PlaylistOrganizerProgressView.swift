import SwiftUI

struct PlaylistOrganizerProgressView: View {
    private static let stillWorkingDelay: TimeInterval = 10

    let startedAt: Date

    @State private var showsStillWorking = false

    var body: some View {
        VStack(spacing: 12) {
            ProgressView(PlaylistOrganizerCopy.progress)
                .accessibilityIdentifier("Playlist Organizer Progress")
            if showsStillWorking {
                Text(PlaylistOrganizerCopy.stillWorking)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: showsStillWorking)
        .task(id: startedAt) {
            await revealStillWorking()
        }
    }

    private func revealStillWorking() async {
        showsStillWorking = false
        let remaining = Self.stillWorkingDelay - Date.now.timeIntervalSince(startedAt)
        do {
            try await Task.sleep(for: .seconds(max(remaining, 0)))
        } catch {
            return
        }
        showsStillWorking = true
    }
}
