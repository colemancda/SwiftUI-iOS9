import CSwiftUIBackend

public struct Text: View {
    let content: String

    public init(_ content: String) {
        self.content = content
    }

    public init(verbatim content: String) {
        self.content = content
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let label = content.withUTF8CString { sui_label_create($0) }!
        if let font = context.font {
            sui_label_set_font(label, font.size.points, font.weight.backendValue)
        }
        if let color = context.foregroundColor {
            sui_label_set_color(label, UInt(color.rgba))
        }
        nodes.append(_Node(view: label))
    }
}
