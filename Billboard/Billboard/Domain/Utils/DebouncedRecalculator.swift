import Foundation

/// Recomputes derived data off the main actor and applies only the newest result.
///
/// Each `schedule` call supersedes the previous one: the earlier task is cancelled, and a
/// result that still arrives for it is dropped. With a debounce, a burst of calls runs the
/// computation once, for the last call.
@MainActor
final class DebouncedRecalculator {
    private let debounceNanoseconds: UInt64
    private let priority: TaskPriority
    private var task: Task<Void, Never>?
    private var generation = 0

    init(debounceNanoseconds: UInt64 = 0, priority: TaskPriority) {
        self.debounceNanoseconds = debounceNanoseconds
        self.priority = priority
    }

    /// - Parameters:
    ///   - snapshot: Reads the inputs on the main actor, once the debounce has elapsed.
    ///   - compute: Derives the output from the inputs in a detached task.
    ///   - apply: Stores the output on the main actor, unless a newer request was made meanwhile.
    func schedule<Input: Sendable, Output: Sendable>(
        snapshot: @escaping @MainActor () -> Input,
        compute: @escaping @Sendable (Input) -> Output,
        apply: @escaping @MainActor (Output) -> Void
    ) {
        generation += 1
        let generation = generation
        let debounceNanoseconds = debounceNanoseconds
        let priority = priority

        task?.cancel()
        task = Task(priority: priority) {
            if debounceNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: debounceNanoseconds)
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else { return }

            let input = snapshot()
            let output = await Task.detached(priority: priority) {
                compute(input)
            }.value

            guard !Task.isCancelled, generation == self.generation else { return }
            self.task = nil
            apply(output)
        }
    }

    /// Cancels the pending computation and drops its result.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }
}
