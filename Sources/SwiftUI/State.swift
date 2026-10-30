import CSwiftUIBackend

/// Storage for one `@State` value. Changing it schedules a re-render.
public class _StateBoxBase {}

public final class _StateBox<Value>: _StateBoxBase {
    var value: Value {
        didSet { sui_schedule_render() }
    }

    init(_ value: Value) {
        self.value = value
    }
}

/// A value owned by a view that survives re-renders. See `Renderer` for how
/// state is matched to views.
@propertyWrapper
public struct State<Value> {
    let box: _StateBox<Value>

    public init(wrappedValue value: Value) {
        if let renderer = currentRenderer {
            box = renderer.stateBox(initialValue: value)
        } else {
            box = _StateBox(value)
        }
    }

    public init(initialValue value: Value) {
        self.init(wrappedValue: value)
    }

    public var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    public var projectedValue: Binding<Value> {
        let box = self.box
        return Binding(get: { box.value }, set: { box.value = $0 })
    }
}

/// A reference to a value owned elsewhere.
@propertyWrapper
public struct Binding<Value> {
    let get: () -> Value
    let set: (Value) -> Void

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.get = get
        self.set = set
    }

    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { _ in })
    }

    public var wrappedValue: Value {
        get { get() }
        nonmutating set { set(newValue) }
    }

    public var projectedValue: Binding<Value> { self }
}
