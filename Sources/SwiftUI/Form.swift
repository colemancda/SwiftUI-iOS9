import CSwiftUIBackend

/// A settings screen: sections of rows on a gray background, in the grouped
/// table style of iOS 9.
public struct Form<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let renderer = context.renderer
        let form = sui_form_create(UInt(truncatingIfNeeded: renderer.makeKey(0x464f_524d_0000_0000)))!
        _List.addRows(of: content, to: form, context: context)
        nodes.append(_Node(view: form, flexibleWidth: true, flexibleHeight: true))
    }
}

/// A group of rows in a `Form` or `List`, with an optional header.
/// Elsewhere, only its content is shown.
public struct Section<Content: View>: View {
    let title: String?
    let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public init(@ViewBuilder content: () -> Content) {
        self.title = nil
        self.content = content()
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        if context.isInList {
            let header: SUIViewRef
            if let title {
                header = title.withUTF8CString { sui_form_header_create($0) }!
            } else {
                header = sui_form_header_create(nil)!
            }
            var node = _Node(view: header)
            node.isListHeader = true
            nodes.append(node)
        }
        content._render(into: &nodes, context: context)
    }
}
