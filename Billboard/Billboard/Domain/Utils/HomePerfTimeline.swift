import Foundation
import os

/// Startup and Home-queue timeline, recorded as signposts in the "perf" category.
///
/// `startRun` opens a "HomeRun" interval (closing the previous run's interval) and every
/// `mark` emits a "HomeStage" event whose message carries the run number, the milliseconds
/// since the run started and since the previous mark, the stage and the optional detail.
/// View them in Instruments (os_signpost or Points of Interest) or with
/// `log stream --level debug --predicate 'category == "perf"'`. Nothing is printed.
///
/// Debug builds only: in Release every call compiles to an empty function, as before.
nonisolated enum HomePerfTimeline {
#if DEBUG
    private struct RunState {
        var runID = 0
        var interval: OSSignpostIntervalState?
        var startedAt: ContinuousClock.Instant?
        var lastMarkAt: ContinuousClock.Instant?
        var emittedOnceKeys: Set<String> = []
    }

    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "BillBoard",
        category: "perf"
    )
    private static let state = OSAllocatedUnfairLock(initialState: RunState())

    static func startRun(_ stage: String, detail: String? = nil) {
        let now = ContinuousClock.now
        state.withLock { state in
            if let previous = state.interval {
                signposter.endInterval("HomeRun", previous)
            }
            state.runID += 1
            state.startedAt = now
            state.lastMarkAt = now
            state.emittedOnceKeys.removeAll(keepingCapacity: true)

            let runID = state.runID
            state.interval = signposter.beginInterval("HomeRun", id: signposter.makeSignpostID(), "run=\(runID)")
            emitStage(stage, detail: detail, runID: runID, totalMs: 0, deltaMs: 0)
        }
    }

    static func mark(_ stage: String, detail: String? = nil) {
        let now = ContinuousClock.now
        state.withLock { state in
            if state.startedAt == nil {
                // A mark before any startRun opens an implicit run, as the print version did.
                state.runID += 1
                state.startedAt = now
                state.emittedOnceKeys.removeAll(keepingCapacity: true)
                let runID = state.runID
                state.interval = signposter.beginInterval("HomeRun", id: signposter.makeSignpostID(), "run=\(runID)")
            }

            let runStartedAt = state.startedAt ?? now
            let previousMarkAt = state.lastMarkAt ?? runStartedAt
            state.lastMarkAt = now
            emitStage(
                stage,
                detail: detail,
                runID: state.runID,
                totalMs: milliseconds(from: runStartedAt, to: now),
                deltaMs: milliseconds(from: previousMarkAt, to: now)
            )
        }
    }

    static func markOnce(_ key: String, stage: String, detail: String? = nil) {
        let shouldEmit = state.withLock { state in
            state.emittedOnceKeys.insert(key).inserted
        }

        guard shouldEmit else { return }
        mark(stage, detail: detail)
    }

    private static func emitStage(_ stage: String, detail: String?, runID: Int, totalMs: Int, deltaMs: Int) {
        let suffix = detail.map { " detail=\($0)" } ?? ""
        signposter.emitEvent(
            "HomeStage",
            "run=\(runID) total=\(totalMs)ms delta=\(deltaMs)ms stage=\(stage, privacy: .public)\(suffix, privacy: .public)"
        )
    }

    private static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int {
        Int((end - start) / .milliseconds(1))
    }
#else
    static func startRun(_ stage: String, detail: String? = nil) {}
    static func mark(_ stage: String, detail: String? = nil) {}
    static func markOnce(_ key: String, stage: String, detail: String? = nil) {}
#endif
}
