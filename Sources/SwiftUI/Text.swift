import CSwiftUIBackend

public struct Text: View {
    let content: String

    public init(_ content: String) {
        self.content = content
    }

    public init(verbatim content: String) {
        self.content = content
    }

    /// Text from a string literal with interpolations, such as
    /// `"\(value, specifier: "%.1f") °C"`. Strings are not localized.
    public init(_ key: LocalizedStringKey) {
        self.content = key.key
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        if let sink = context.textSink {
            sink.text += content
            return
        }
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

/// Collects the strings of the `Text` views rendered while it is set.
public final class _TextSink {
    var text = ""
}
