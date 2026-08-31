import AudioToolbox
import CoreAudio
import Foundation
import os

extension ProcessTap {
    /// Park long-idle IO without letting the process escape at full volume.
    /// `.muted` keeps native output silent while the aggregate is stopped; one
    /// shared lightweight watcher resumes IO as soon as the process runs again.
    @MainActor
    func updatePlaybackState(isPlaying: Bool) {
        guard isPlaying != isProcessPlaying else { return }
        isProcessPlaying = isPlaying
        idleTask?.cancel()
        idleTask = nil

        if isPlaying {
            if isSuspended { resumeIO() }
            return
        }

        idleTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(30), tolerance: .seconds(2))
            } catch {
                return
            }
            guard let self, !isProcessPlaying else { return }
            idleTask = nil
            suspendIO()
        }
    }

    @MainActor
    func resumeIfOutputStarted() {
        guard isSuspended, processObjectIDs.contains(where: { $0.readProcessIsRunningOutput() }) else { return }
        isProcessPlaying = true
        resumeIO()
    }

    @MainActor
    func stopIdleLifecycle() {
        idleTask?.cancel()
        idleTask = nil
        if isSuspended { ProcessTapWakeMonitor.shared.unwatch(self) }
        isSuspended = false
    }

    @MainActor
    private func suspendIO() {
        guard !isSuspended, aggregateID.isValid, let procID else { return }
        do {
            try setTapMuteBehavior(.muted)
            do {
                try checked(AudioDeviceStop(aggregateID, procID), "suspend aggregate device")
            } catch {
                try? setTapMuteBehavior(.mutedWhenTapped)
                throw error
            }
            isSuspended = true
            ProcessTapWakeMonitor.shared.watch(self)
            let id = tapID
            Self.logger.debug("Suspended idle tap \(id)")
        } catch {
            Self.logger.error("Failed to suspend idle tap: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func resumeIO() {
        guard isSuspended, aggregateID.isValid, let procID else { return }
        idleTask?.cancel()
        idleTask = nil
        do {
            try checked(AudioDeviceStart(aggregateID, procID), "resume aggregate device")
            isSuspended = false
            ProcessTapWakeMonitor.shared.unwatch(self)
            do {
                try setTapMuteBehavior(.mutedWhenTapped)
            } catch {
                // `.muted` plus a running reader still produces correct output;
                // keep audio alive and report the HAL problem for diagnostics.
                Self.logger.error("Failed to restore tap mute behavior: \(error.localizedDescription)")
            }
            let id = tapID
            Self.logger.debug("Resumed tap \(id)")
            onOutputResumed?()
        } catch {
            Self.logger.error("Failed to resume tap: \(error.localizedDescription)")
            // Destroying the muted tap restores native audio. The process-list
            // refresh then lets MixerEngine rebuild clean plumbing.
            invalidate()
            onOutputResumed?()
        }
    }

    @MainActor
    private func setTapMuteBehavior(_ behavior: CATapMuteBehavior) throws {
        guard tapID.isValid, let tapDescription else { return }
        let previous = tapDescription.muteBehavior
        tapDescription.muteBehavior = behavior
        do {
            try tapID.writeObjectReference(kAudioTapPropertyDescription, value: tapDescription)
        } catch {
            tapDescription.muteBehavior = previous
            throw error
        }
    }
}
