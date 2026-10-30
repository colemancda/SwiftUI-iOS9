/// A type-erased view, for returning different view types from one `body`.
public struct AnyView: View {
    let render: (inout [_Node], _RenderContext) -> Void

    public init<V: View>(_ view: V) {
        render = { nodes, context in
            view._render(into: &nodes, context: context)
        }
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        render(&nodes, context)
    }
}
