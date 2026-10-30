/// Runs actions when a view appears in, or disappears from, the rendered tree.
/// A view appears when a render first includes it at its position.
public struct _AppearanceModifier<Content: View>: View {
    let content: Content
    let onAppear: (() -> Void)?
    let onDisappear: (() -> Void)?

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let renderer = context.renderer
        let key = renderer.makeKey(0x4150_5045_4152_0000)
        renderer.register(Renderer.Appearance(key: key, onAppear: onAppear, onDisappear: onDisappear))
        content._render(into: &nodes, context: context)
    }
}

extension View {
    public func onAppear(perform action: (() -> Void)? = nil) -> some View {
        _AppearanceModifier(content: self, onAppear: action, onDisappear: nil)
    }

    public func onDisappear(perform action: (() -> Void)? = nil) -> some View {
        _AppearanceModifier(content: self, onAppear: nil, onDisappear: action)
    }
}
