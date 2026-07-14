import Foundation
import RepoDeckKit

/// Single coordinator for per-repo auto-fetch: one 60-second tick loop that
/// fetches every repo whose configured interval has elapsed. One loop (not
/// N per-repo tasks) keeps the interlocks with scanning and bulk operations
/// in one place and avoids long-lived task sprawl.
@MainActor
final class AutoFetchScheduler {
    private unowned let model: AppModel
    private var tickTask: Task<Void, Never>?
    /// Last trigger time per repo id. In-memory only; initialized lazily to
    /// the scheduler's start time, so the first auto-fetch of any repo
    /// happens one full interval after launch — never a thundering herd at
    /// startup.
    private var lastFetchAt: [String: Date] = [:]
    private var startedAt = Date()

    init(model: AppModel) {
        self.model = model
    }

    /// Idempotent: cancels any prior loop and resets `startedAt` so the
    /// "one interval after launch" grace period restarts too.
    func start() {
        tickTask?.cancel()
        startedAt = Date()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await self?.tick()
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func tick() async {
        // A scan replaces `model.repos` wholesale and a bulk op already owns
        // every repo's `isBusy`; skip the whole tick rather than race either.
        guard !model.isScanning, model.bulkProgress == nil else { return }

        let now = Date()
        var due: [RepoViewModel] = []
        for vm in model.repos {
            guard let interval = model.settings(for: vm.id).autoFetchInterval.seconds else { continue }
            let last = lastFetchAt[vm.id] ?? startedAt
            guard now.timeIntervalSince(last) >= interval, !vm.isBusy, !vm.isMissing else { continue }
            due.append(vm)
        }
        guard !due.isEmpty else { return }

        // Stamp at trigger time, before the fetch runs: a slow fetch must
        // not leave its repo looking overdue again on the very next tick.
        for vm in due {
            lastFetchAt[vm.id] = now
        }

        // Fan out: real concurrency is bounded by the background lane (≤4)
        // in ProcessRunner; no extra limiter here (same comment style as
        // `runBulk`).
        await withTaskGroup(of: Void.self) { group in
            for vm in due {
                group.addTask { await vm.autoFetch() }
            }
        }
    }
}
