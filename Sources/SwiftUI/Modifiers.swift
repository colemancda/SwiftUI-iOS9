import CSwiftUIBackend

extension View {
    public func font(_ font: Font?) -> some View {
        _EnvironmentModifier(content: self) { $0.font = font }
    }

    public func foregroundColor(_ color: Color?) -> some View {
        _EnvironmentModifier(content: self) { $0.foregroundColor = color }
    }

    public func foregroundStyle(_ color: Color) -> some View {
        foregroundColor(color)
    }

    public func padding(_ length: CGFloat) -> some View {
        padding(.all, length)
    }

    public func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View {
        _PaddingModifier(content: self, edges: edges, length: length ?? 16)
    }

    public func frame(width: CGFloat? = nil, height: CGFloat? = nil) -> some View {
        _FrameModifier(content: self, width: width, height: height, maxWidth: nil, maxHeight: nil)
    }

    /// Pass `.infinity` to take all the space offered in that dimension.
    public func frame(maxWidth: CGFloat? = nil, maxHeight: CGFloat? = nil) -> some View {
        _FrameModifier(content: self, width: nil, height: nil, maxWidth: maxWidth, maxHeight: maxHeight)
    }

    /// Disables the controls in this view.
    public func disabled(_ disabled: Bool) -> some View {
        _EnvironmentModifier(content: self) { if disabled { $0.isEnabled = false } }
    }

    public func background(_ color: Color) -> some View {
        _BackgroundModifier(content: self, color: color)
    }
}

/// Changes the context for `content` and its descendants only.
public struct _EnvironmentModifier<Content: View>: View {
    let content: Content
    let update: (_RenderContext) -> Void

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let savedFont = context.font
        let savedColor = context.foregroundColor
        let savedObjects = context.environmentObjects
        let savedEnabled = context.isEnabled
        update(context)
        content._render(into: &nodes, context: context)
        context.font = savedFont
        context.foregroundColor = savedColor
        context.environmentObjects = savedObjects
        context.isEnabled = savedEnabled
    }
}

public struct _PaddingModifier<Content: View>: View {
    let content: Content
    let edges: Edge.Set
    let length: CGFloat

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        var children: [_Node] = []
        content._render(into: &children, context: context)
        let child = _Node.stacked(children, axis: .vertical)
        func inset(_ edge: Edge.Set) -> Int {
            edges.contains(edge) ? length.points : 0
        }
        let padded = sui_padding_create(child.view, inset(.top), inset(.leading), inset(.bottom), inset(.trailing))!
        nodes.append(_Node(view: padded, flexibleWidth: child.flexibleWidth, flexibleHeight: child.flexibleHeight))
    }
}

public struct _FrameModifier<Content: View>: View {
    let content: Content
    let width: CGFloat?
    let height: CGFloat?
    let maxWidth: CGFloat?
    let maxHeight: CGFloat?

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        var children: [_Node] = []
        content._render(into: &children, context: context)
        var node = _Node.stacked(children, axis: .vertical)
        sui_view_set_size(node.view, width?.points ?? -1, height?.points ?? -1)
        if width != nil { node.flexibleWidth = false }
        if height != nil { node.flexibleHeight = false }
        if let maxWidth, maxWidth == .infinity { node.flexibleWidth = true }
        if let maxHeight, maxHeight == .infinity { node.flexibleHeight = true }
        nodes.append(node)
    }
}

public struct _BackgroundModifier<Content: View>: View {
    let content: Content
    let color: Color

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        var children: [_Node] = []
        content._render(into: &children, context: context)
        let child = _Node.stacked(children, axis: .vertical)
        let background = sui_background_create(child.view, UInt(color.rgba))!
        nodes.append(_Node(view: background, flexibleWidth: child.flexibleWidth, flexibleHeight: child.flexibleHeight))
    }
}
