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

    /// Callbacks referenced by the views on screen; the backend holds
    /// unretained pointers to these.
    private var actions: [AnyObject] = []
    private var pendingActions: [AnyObject] = []

    /// `onAppear`/`onDisappear` handlers of the views on screen, by identity.
    private var appearances: [Appearance] = []
    private var pendingAppearances: [Appearance] = []

    /// The context of the pass in progress, for property wrappers that read
    /// the environment.
    private(set) var currentContext: _RenderContext?

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
        pendingAppearances = []

        sui_render_begin()
        var nodes: [_Node] = []
        let context = _RenderContext(renderer: self)
        currentContext = context
        renderRoot(&nodes, context)
        let root = Renderer.combine(nodes)
        sui_render_commit(root.view, root.flexibleWidth ? 1 : 0, root.flexibleHeight ? 1 : 0)
        currentContext = nil

        // The old views are off screen now, so their actions can go.
        actions = pendingActions
        pendingActions = []
        slots.removeAll { $0.lastUsed != generation }
        isRendering = false

        // Handlers may change state, which schedules another pass.
        let previous = appearances
        appearances = pendingAppearances
        pendingAppearances = []
        for old in previous where !appearances.contains(where: { $0.key == old.key }) {
            old.onDisappear?()
        }
        for new in appearances where !previous.contains(where: { $0.key == new.key }) {
            new.onAppear?()
        }
    }

    /// Wraps several top-level views in a vertical stack, as SwiftUI does.
    static func combine(_ nodes: [_Node]) -> _Node {
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

    /// Like `enterScope()`, but keyed by `identity` instead of position, so
    /// state follows an element of a `ForEach` when the data reorders.
    func enterScope(identity: Int) -> Scope {
        let saved = enterScope()
        scopeKey = Renderer.mix(saved.key ^ 0x4944_0000_0000_0000, UInt64(UInt(bitPattern: identity)))
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

    /// A key for the next view at this position that needs an identity
    /// across passes, such as a navigation link or a list.
    func makeKey(_ salt: UInt64) -> UInt64 {
        let key = Renderer.mix(scopeKey ^ salt, stateIndex)
        stateIndex += 1
        return key
    }

    /// Like `stateBox(initialValue:)`, but only makes the value for a new slot.
    func stateBox<Value>(make: () -> Value) -> _StateBox<Value> {
        guard isRendering else { return _StateBox(make()) }
        let key = Renderer.mix(scopeKey ^ 0x5354_4154_4500_0000, stateIndex)
        if let index = slots.firstIndex(where: { $0.key == key }) {
            stateIndex += 1
            slots[index].lastUsed = generation
            return unsafeDowncast(slots[index].box, to: _StateBox<Value>.self)
        }
        return stateBox(initialValue: make())
    }

    func retain(_ action: AnyObject) {
        pendingActions.append(action)
    }

    func register(_ appearance: Appearance) {
        pendingAppearances.append(appearance)
    }

    struct Appearance {
        let key: UInt64
        let onAppear: (() -> Void)?
        let onDisappear: (() -> Void)?
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

/// Like `_ActionBox`, for callbacks that take an index.
final class _IndexActionBox {
    let action: (Int) -> Void

    init(_ action: @escaping (Int) -> Void) {
        self.action = action
    }

    func register(with renderer: Renderer) -> (SUIIndexCallback, UnsafeMutableRawPointer) {
        renderer.retain(self)
        let callback: SUIIndexCallback = { context, index in
            Unmanaged<_IndexActionBox>.fromOpaque(context!).takeUnretainedValue().action(index)
        }
        return (callback, Unmanaged.passUnretained(self).toOpaque())
    }
}
