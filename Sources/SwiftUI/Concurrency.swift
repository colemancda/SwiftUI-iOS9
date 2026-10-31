// Embedded Swift doesn't import the concurrency module implicitly; re-exporting
// it lets app code use `Task` and `async` with just `import SwiftUI`.
@_exported import _Concurrency
import CSwiftUIBackend

// Tasks run on the main queue; see Executor.c.

extension Task where Success == Never, Failure == Never {
    /// Suspends the current task for at least `duration` nanoseconds, then
    /// throws `CancellationError` if the task was cancelled meanwhile.
    ///
    /// Embedded Swift has no clocks, so its own `Task.sleep` is unavailable;
    /// this one uses a main-queue timer. Cancellation doesn't end the wait early.
    public static func sleep(nanoseconds duration: UInt64) async throws {
        let milliseconds = duration / 1_000_000 + (duration % 1_000_000 == 0 ? 0 : 1)
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            let context = Unmanaged.passRetained(_SleepContinuation(continuation)).toOpaque()
            sui_dispatch_main_after(UInt(clamping: milliseconds), { context in
                Unmanaged<_SleepContinuation>.fromOpaque(context!).takeRetainedValue().continuation.resume()
            }, context)
        }
        if Task<Never, Never>.isCancelled {
            throw _Concurrency.CancellationError()
        }
    }
}

final class _SleepContinuation {
    let continuation: UnsafeContinuation<Void, Never>

    init(_ continuation: UnsafeContinuation<Void, Never>) {
        self.continuation = continuation
    }
}

extension View {
    /// Starts `action` in a task when this view appears, and cancels it when
    /// the view disappears.
    public func task(_ action: @escaping () async -> Void) -> some View {
        _TaskModifier(content: self, action: action)
    }
}

public struct _TaskModifier<Content: View>: View {
    let content: Content
    let action: () async -> Void

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let renderer = context.renderer
        // The running task outlives this render, so it is kept in a state slot.
        let task = renderer.stateBox(initialValue: Task<Void, Never>?.none)
        let action = self.action
        renderer.register(Renderer.Appearance(
            key: renderer.makeKey(0x5441_534b_0000_0000),
            onAppear: { task.value = Task { await action() } },
            onDisappear: {
                task.value?.cancel()
                task.value = nil
            }
        ))
        content._render(into: &nodes, context: context)
    }
}
