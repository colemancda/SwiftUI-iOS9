import CSwiftUIBackend

/// A piece of user interface. Same shape as SwiftUI's `View`.
@MainActor
public protocol View {
    associatedtype Body: View

    @ViewBuilder var body: Body { get }

    /// Renders this view into backend views. Primitive views (Text, VStack, …)
    /// implement it; composed views use the default, which renders `body`.
    func _render(into nodes: inout [_Node], context: _RenderContext)
}

extension View {
    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let scope = context.renderer.enterScope()
        body._render(into: &nodes, context: context)
        context.renderer.exitScope(scope)
    }
}

/// Primitive views have no body.
extension Never: View {
    public var body: Never { fatalError("Never has no body") }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {}
}

/// A rendered backend view and how it behaves in layout.
public struct _Node {
    var view: SUIViewRef
    /// Takes all the width it is offered, like a view containing a `Spacer`.
    var flexibleWidth: Bool = false
    var flexibleHeight: Bool = false
    /// Spacers only stretch along their stack's axis.
    var isSpacer: Bool = false
    /// Set on a `NavigationLink`'s row, which a `List` shows with a chevron
    /// and makes tappable.
    var navigationAction: _ActionBox? = nil
    /// A `Section` header, which a list adds as is rather than as a row.
    var isListHeader: Bool = false
}

/// What a view inherits from its ancestors while rendering.
public final class _RenderContext {
    let renderer: Renderer
    var font: Font?
    var foregroundColor: Color?
    /// Objects from `environmentObject(_:)`, innermost last.
    var environmentObjects: [(ObjectIdentifier, AnyObject)] = []
    /// The navigation level being rendered, which collects its title, bar
    /// items and links.
    var navigation: _NavigationLevel?
    /// Set while rendering the rows of a `List`.
    var isInList = false
    /// Cleared by `disabled(_:)`.
    var isEnabled = true
    /// Cleared while rendering a navigation level covered by a pushed one, so
    /// its views disappear, as in SwiftUI, though they stay rendered.
    var isVisible = true
    /// While set, `Text` adds its string here instead of making a label,
    /// so a `Picker` can read its options' titles.
    var textSink: _TextSink?
    /// Set while a `Picker` collects its options.
    var pickerOptions: _PickerOptions?

    init(renderer: Renderer) {
        self.renderer = renderer
    }
}

public struct EmptyView: View {
    public init() {}

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {}
}

/// Two views rendered one after the other. ViewBuilder nests these for longer blocks.
public struct TupleView<First: View, Second: View>: View {
    let first: First
    let second: Second

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        first._render(into: &nodes, context: context)
        second._render(into: &nodes, context: context)
    }
}

/// The result of an `if` without `else` in a ViewBuilder.
public struct OptionalView<Wrapped: View>: View {
    let content: Wrapped?

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        if let content {
            content._render(into: &nodes, context: context)
        }
    }
}

/// The result of an `if`/`else` in a ViewBuilder.
public struct ConditionalView<TrueContent: View, FalseContent: View>: View {
    enum Storage {
        case first(TrueContent)
        case second(FalseContent)
    }

    let storage: Storage

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        switch storage {
        case .first(let content): content._render(into: &nodes, context: context)
        case .second(let content): content._render(into: &nodes, context: context)
        }
    }
}

@resultBuilder
@MainActor
public enum ViewBuilder {
    public static func buildBlock() -> EmptyView {
        EmptyView()
    }

    public static func buildExpression<Content: View>(_ content: Content) -> Content {
        content
    }

    public static func buildPartialBlock<Content: View>(first content: Content) -> Content {
        content
    }

    public static func buildPartialBlock<Accumulated: View, Next: View>(
        accumulated: Accumulated,
        next: Next
    ) -> TupleView<Accumulated, Next> {
        TupleView(first: accumulated, second: next)
    }

    public static func buildOptional<Content: View>(_ content: Content?) -> OptionalView<Content> {
        OptionalView(content: content)
    }

    public static func buildEither<TrueContent: View, FalseContent: View>(
        first content: TrueContent
    ) -> ConditionalView<TrueContent, FalseContent> {
        ConditionalView(storage: .first(content))
    }

    public static func buildEither<TrueContent: View, FalseContent: View>(
        second content: FalseContent
    ) -> ConditionalView<TrueContent, FalseContent> {
        ConditionalView(storage: .second(content))
    }
}
