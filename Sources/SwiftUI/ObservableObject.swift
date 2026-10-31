import CSwiftUIBackend

/// An object whose `@Published` properties update the views that use it.
///
/// There is no Combine here: since every update re-renders the whole view
/// tree, changing a published property just schedules a render.
public protocol ObservableObject: AnyObject {}

/// A property of an `ObservableObject` that re-renders views when it changes.
@propertyWrapper
public struct Published<Value> {
    var value: Value

    public init(wrappedValue value: Value) {
        self.value = value
    }

    public init(initialValue value: Value) {
        self.init(wrappedValue: value)
    }

    public var wrappedValue: Value {
        get { value }
        set {
            value = newValue
            sui_schedule_render()
        }
    }
}

/// An `ObservableObject` passed to a view by its parent.
@propertyWrapper
public struct ObservedObject<ObjectType: ObservableObject> {
    public var wrappedValue: ObjectType

    public init(wrappedValue: ObjectType) {
        self.wrappedValue = wrappedValue
    }
}

/// An `ObservableObject` a view creates once and keeps across renders,
/// matched by position like `@State`.
@propertyWrapper
public struct StateObject<ObjectType: ObservableObject> {
    let box: _StateBox<ObjectType>

    public init(wrappedValue: @autoclosure () -> ObjectType) {
        if let renderer = currentRenderer {
            box = renderer.stateBox(make: wrappedValue)
        } else {
            box = _StateBox(wrappedValue())
        }
    }

    public var wrappedValue: ObjectType {
        box.value
    }
}

/// An `ObservableObject` supplied by an ancestor with `environmentObject(_:)`.
@propertyWrapper
public struct EnvironmentObject<ObjectType: ObservableObject> {
    /// Resolved when the view is created during a render, or else on first
    /// use while rendering, and kept so that actions and tasks running later
    /// still see the object.
    final class Storage {
        var object: ObjectType?
    }

    let storage = Storage()

    public init() {
        // A view made in its parent's `body` already sees the parent's
        // environment. One made before its own `environmentObject(_:)`
        // modifier renders resolves later, in its `body`.
        storage.object = Self.lookup()
    }

    public var wrappedValue: ObjectType {
        if let object = storage.object {
            return object
        }
        if let object = Self.lookup() {
            storage.object = object
            return object
        }
        fatalError("No ObservableObject of this type found. A View.environmentObject(_:) for it may be missing as an ancestor of this view.")
    }

    static func lookup() -> ObjectType? {
        let id = ObjectIdentifier(ObjectType.self)
        guard let objects = currentRenderer?.currentContext?.environmentObjects,
              let match = objects.last(where: { $0.0 == id }) else {
            return nil
        }
        return unsafeDowncast(match.1, to: ObjectType.self)
    }
}

extension View {
    /// Makes `object` available to `@EnvironmentObject` properties of this
    /// view's descendants.
    public func environmentObject<T: ObservableObject>(_ object: T) -> some View {
        _EnvironmentModifier(content: self) {
            $0.environmentObjects.append((ObjectIdentifier(T.self), object))
        }
    }
}
