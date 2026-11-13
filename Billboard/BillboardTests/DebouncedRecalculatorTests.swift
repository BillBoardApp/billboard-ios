import Foundation
import XCTest
@testable import Billboard

/// `DebouncedRecalculator`: a burst of requests is computed once, a newer request
/// supersedes an in-flight one, and `cancel()` drops pending work.
@MainActor
final class DebouncedRecalculatorTests: XCTestCase {
    @MainActor
    private final class Recorder {
        var applied: [Int] = []
    }

    /// Counts computations, which run off the main actor.
    private final class ComputeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    func testBurstIsComputedOnceWithTheLastInput() async {
        let recalculator = DebouncedRecalculator(debounceNanoseconds: 50_000_000, priority: .userInitiated)
        let recorder = Recorder()
        let counter = ComputeCounter()
        let applied = expectation(description: "applied")

        for value in 1...5 {
            recalculator.schedule(
                snapshot: { value },
                compute: { input in
                    counter.increment()
                    return input * 10
                },
                apply: { output in
                    recorder.applied.append(output)
                    applied.fulfill()
                }
            )
        }

        await fulfillment(of: [applied], timeout: 30)
        XCTAssertEqual(recorder.applied, [50])
        XCTAssertEqual(counter.value, 1)
    }

    func testRequestMadeWhileOneIsInFlightWins() async {
        let recalculator = DebouncedRecalculator(priority: .userInitiated)
        let recorder = Recorder()
        let counter = ComputeCounter()
        let applied = expectation(description: "newest applied")

        recalculator.schedule(
            snapshot: {
                // The first request has started; supersede it before it computes.
                recalculator.schedule(
                    snapshot: { 2 },
                    compute: { input in
                        counter.increment()
                        return input
                    },
                    apply: { output in
                        recorder.applied.append(output)
                        applied.fulfill()
                    }
                )
                return 1
            },
            compute: { input in
                counter.increment()
                return input
            },
            apply: { recorder.applied.append($0) }
        )

        await fulfillment(of: [applied], timeout: 30)
        // Give the superseded request time to finish; its result must be dropped.
        for _ in 0..<500 where counter.value < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(recorder.applied, [2])
    }

    func testCancelDropsPendingAndInFlightResults() async {
        let debounced = DebouncedRecalculator(debounceNanoseconds: 50_000_000, priority: .userInitiated)
        let immediate = DebouncedRecalculator(priority: .userInitiated)
        let recorder = Recorder()

        debounced.schedule(snapshot: { 1 }, compute: { $0 }, apply: { recorder.applied.append($0) })
        debounced.cancel()

        immediate.schedule(
            snapshot: {
                // The request has started; cancel it before it computes.
                immediate.cancel()
                return 2
            },
            compute: { $0 },
            apply: { recorder.applied.append($0) }
        )

        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(recorder.applied, [])
    }
}
