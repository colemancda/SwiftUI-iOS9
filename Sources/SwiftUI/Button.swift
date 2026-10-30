import CSwiftUIBackend

public struct Button<Label: View>: View {
    let action: () -> Void
    let label: Label
    /// Set by `init(_:action:)`, which renders as a UIKit system button.
    let title: String?

    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
        self.title = nil
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let (callback, actionContext) = _ActionBox(action).register(with: context.renderer)

        if let title {
            let button = title.withUTF8CString { sui_button_create($0, callback, actionContext) }!
            if let font = context.font {
                sui_button_set_font(button, font.size.points, font.weight.backendValue)
            }
            if let color = context.foregroundColor {
                sui_button_set_color(button, UInt(color.rgba))
            }
            nodes.append(_Node(view: button))
            return
        }

        // Custom labels are tinted like SwiftUI's default button style.
        let savedColor = context.foregroundColor
        context.foregroundColor = savedColor ?? .accentColor
        var content: [_Node] = []
        label._render(into: &content, context: context)
        context.foregroundColor = savedColor

        let labelNode = _Node.stacked(content, axis: .vertical)
        let control = sui_tappable_create(labelNode.view, callback, actionContext)!
        nodes.append(_Node(view: control, flexibleWidth: labelNode.flexibleWidth, flexibleHeight: labelNode.flexibleHeight))
    }
}

extension Button where Label == Text {
    public init(_ title: String, action: @escaping () -> Void) {
        self.action = action
        self.label = Text(title)
        self.title = title
    }
}
