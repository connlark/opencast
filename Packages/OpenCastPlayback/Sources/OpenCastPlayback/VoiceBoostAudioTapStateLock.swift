import os.lock

nonisolated final class VoiceBoostAudioTapStateLock {
    private var lock = os_unfair_lock_s()

    func withLock<Result>(_ body: () -> Result) -> Result {
        os_unfair_lock_lock(&lock)
        defer {
            os_unfair_lock_unlock(&lock)
        }
        return body()
    }

    func withLockIfAvailable<Result>(_ body: () -> Result) -> Result? {
        guard os_unfair_lock_trylock(&lock) else {
            return nil
        }
        defer {
            os_unfair_lock_unlock(&lock)
        }
        return body()
    }
}
