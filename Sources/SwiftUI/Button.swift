import CSwiftUIBackend

public struct Button<Label: View>: View {
    let action: @MainActor () -> Void
    let label: Label
    /// Set by `init(_:action:)`, which renders as a UIKit system button.
    let title: String?
    let role: ButtonRole?

    public init(action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
        self.title = nil
        self.role = nil
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let (callback, actionContext) = _ActionBox(action).register(with: context.renderer)

        if let title {
            let button = title.withUTF8CString { sui_button_create($0, callback, actionContext) }!
            if let font = context.font {
                sui_button_set_font(button, font.size.points, font.weight.backendValue)
            }
            if let color = role == .destructive ? .red : context.foregroundColor {
                sui_button_set_color(button, UInt(color.rgba))
            }
            if !context.isEnabled {
                sui_control_set_enabled(button, 0)
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
        if !context.isEnabled {
            sui_control_set_enabled(control, 0)
        }
        nodes.append(_Node(view: control, flexibleWidth: labelNode.flexibleWidth, flexibleHeight: labelNode.flexibleHeight))
    }
}

extension Button where Label == Text {
    public init(_ title: String, action: @escaping @MainActor () -> Void) {
        self.init(title, role: nil, action: action)
    }

    public init(_ title: String, role: ButtonRole?, action: @escaping @MainActor () -> Void) {
        self.action = action
        self.label = Text(title)
        self.title = title
        self.role = role
    }
}

/// What a button does. Destructive buttons are red.
public struct ButtonRole: Equatable, Sendable {
    let rawValue: UInt8

    public static let destructive = ButtonRole(rawValue: 0)
    public static let cancel = ButtonRole(rawValue: 1)
}

/// Button styles are accepted for compatibility; buttons look the same.
public protocol PrimitiveButtonStyle {}

public struct DefaultButtonStyle: PrimitiveButtonStyle {}
public struct BorderlessButtonStyle: PrimitiveButtonStyle {}
public struct PlainButtonStyle: PrimitiveButtonStyle {}
public struct BorderedButtonStyle: PrimitiveButtonStyle {}

extension PrimitiveButtonStyle where Self == DefaultButtonStyle {
    public static var automatic: DefaultButtonStyle { DefaultButtonStyle() }
}

extension PrimitiveButtonStyle where Self == BorderlessButtonStyle {
    public static var borderless: BorderlessButtonStyle { BorderlessButtonStyle() }
}

extension PrimitiveButtonStyle where Self == PlainButtonStyle {
    public static var plain: PlainButtonStyle { PlainButtonStyle() }
}

extension PrimitiveButtonStyle where Self == BorderedButtonStyle {
    public static var bordered: BorderedButtonStyle { BorderedButtonStyle() }
}

extension View {
    public func buttonStyle<S: PrimitiveButtonStyle>(_ style: S) -> Self {
        self
    }
}
