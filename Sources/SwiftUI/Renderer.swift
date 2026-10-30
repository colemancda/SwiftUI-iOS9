import CSwiftUIBackend

/// Rebuilds the whole UIKit view tree from the app's views on every update.
///
/// State is identified by position, since Embedded Swift has no reflection to
/// find a view's `@State` properties: each composed view's `body` runs in a
/// scope keyed by its parent's scope and its order among its siblings, and
/// each `State` created while that body runs takes the next slot in it.
/// A view whose position changes (say, behind an `if`) gets fresh state.
final class Renderer {
    private struct Slot {
        let key: UInt64
        let box: _StateBoxBase
        var lastUsed: UInt64
    }

    struct Scope {
        let key: UInt64
        let stateIndex: UInt64
        let childIndex: UInt64
    }

    private let renderRoot: (inout [_Node], _RenderContext) -> Void
    private var slots: [Slot] = []
    private var generation: UInt64 = 0

    private var scopeKey: UInt64 = 0
    private var stateIndex: UInt64 = 0
    private var childIndex: UInt64 = 0
    private(set) var isRendering = false

    /// Button actions referenced by the views on screen; the backend holds
    /// unretained pointers to these.
    private var actions: [_ActionBox] = []
    private var pendingActions: [_ActionBox] = []

    init(renderRoot: @escaping (inout [_Node], _RenderContext) -> Void) {
        self.renderRoot = renderRoot
    }

    func render() {
        isRendering = true
        generation &+= 1
        scopeKey = 0xcbf2_9ce4_8422_2325
        stateIndex = 0
        childIndex = 0
        pendingActions = []

        sui_render_begin()
        var nodes: [_Node] = []
        renderRoot(&nodes, _RenderContext(renderer: self))
        let root = Renderer.combine(nodes)
        sui_render_commit(root.view, root.flexibleWidth ? 1 : 0, root.flexibleHeight ? 1 : 0)

        // The old views are off screen now, so their actions can go.
        actions = pendingActions
        pendingActions = []
        slots.removeAll { $0.lastUsed != generation }
        isRendering = false
    }

    /// Wraps several top-level views in a vertical stack, as SwiftUI does.
    private static func combine(_ nodes: [_Node]) -> _Node {
        if nodes.count == 1 { return nodes[0] }
        let stack = sui_stack_create(Int(SUIAxisVertical), 8, Int(SUIAlignmentCenter))!
        var root = _Node(view: stack)
        for node in nodes {
            sui_stack_add(stack, node.view, node.flexibleWidth ? 1 : 0)
            root.flexibleWidth = root.flexibleWidth || (node.flexibleWidth && !node.isSpacer)
            root.flexibleHeight = root.flexibleHeight || node.flexibleHeight
        }
        return root
    }

    // MARK: Scopes and state

    func enterScope() -> Scope {
        let saved = Scope(key: scopeKey, stateIndex: stateIndex, childIndex: childIndex + 1)
        scopeKey = Renderer.mix(scopeKey, childIndex)
        childIndex = 0
        stateIndex = 0
        return saved
    }

    func exitScope(_ scope: Scope) {
        scopeKey = scope.key
        stateIndex = scope.stateIndex
        childIndex = scope.childIndex
    }

    func stateBox<Value>(initialValue: Value) -> _StateBox<Value> {
        guard isRendering else { return _StateBox(initialValue) }
        let key = Renderer.mix(scopeKey ^ 0x5354_4154_4500_0000, stateIndex)
        stateIndex += 1
        if let index = slots.firstIndex(where: { $0.key == key }) {
            slots[index].lastUsed = generation
            return unsafeDowncast(slots[index].box, to: _StateBox<Value>.self)
        }
        let box = _StateBox(initialValue)
        slots.append(Slot(key: key, box: box, lastUsed: generation))
        return box
    }

    func retain(_ action: _ActionBox) {
        pendingActions.append(action)
    }

    /// FNV-1a over the 8 bytes of `value`, continuing from `hash`.
    private static func mix(_ hash: UInt64, _ value: UInt64) -> UInt64 {
        var result = hash
        var remaining = value
        for _ in 0..<8 {
            result = (result ^ (remaining & 0xff)) &* 0x0000_0100_0000_01b3
            remaining >>= 8
        }
        return result
    }
}

/// The running app's renderer. Set once by `App.main()`.
nonisolated(unsafe) var currentRenderer: Renderer?

/// A button action the backend calls through a C function pointer.
public final class _ActionBox {
    let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    /// Registers this action for the current render pass and returns the
    /// callback and context to hand to the backend.
    func register(with renderer: Renderer) -> (SUICallback, UnsafeMutableRawPointer) {
        renderer.retain(self)
        let callback: SUICallback = { context in
            Unmanaged<_ActionBox>.fromOpaque(context!).takeUnretainedValue().action()
        }
        return (callback, Unmanaged.passUnretained(self).toOpaque())
    }
}
