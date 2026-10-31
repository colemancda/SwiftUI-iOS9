import CSwiftUIBackend

/// A stack of views with a navigation bar, backed by a `UINavigationController`.
///
/// The stack is a list of navigation link keys, one per pushed level. Each
/// pass renders the root, then the destination of the link pushed from it,
/// and so on, so pushed views stay live: they re-render with fresh data from
/// the link that pushed them. If that link is gone, its level is popped.
public struct NavigationView<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let renderer = context.renderer
        let navigationKey = renderer.makeKey(0x4e41_5600_0000_0000)
        let path = renderer.stateBox(initialValue: [UInt64]())
        let navigation = sui_navigation_create(UInt(truncatingIfNeeded: navigationKey))!

        let savedLevel = context.navigation
        let savedInList = context.isInList
        let savedVisible = context.isVisible
        context.isInList = false
        var level = _NavigationLevel(path: path, depth: 0)
        var count = 0
        while true {
            context.navigation = level
            // Only the top level is on screen.
            context.isVisible = savedVisible && count == path.value.count
            var children: [_Node] = []
            if count == 0 {
                content._render(into: &children, context: context)
            } else {
                // Keyed by the link, so another link's destination gets fresh state.
                let key = path.value[count - 1]
                let scope = renderer.enterScope(identity: Int(truncatingIfNeeded: key))
                level.parent!.links[key]!(&children, context)
                renderer.exitScope(scope)
            }
            let node = _Node.stacked(children, axis: .vertical)
            let trailing = level.trailingItem.map { Renderer.combine($0) }
            if let title = level.title {
                title.withUTF8CString {
                    sui_navigation_set_level(navigation, count, node.view, node.flexibleWidth ? 1 : 0, node.flexibleHeight ? 1 : 0, $0, trailing?.view)
                }
            } else {
                sui_navigation_set_level(navigation, count, node.view, node.flexibleWidth ? 1 : 0, node.flexibleHeight ? 1 : 0, nil, trailing?.view)
            }
            count += 1
            // Stop at the top of the stack, or where a pushed link disappeared.
            guard count <= path.value.count, level.links[path.value[count - 1]] != nil else {
                break
            }
            let next = _NavigationLevel(path: path, depth: count)
            next.parent = level
            level = next
        }
        context.navigation = savedLevel
        context.isInList = savedInList
        context.isVisible = savedVisible

        if count - 1 < path.value.count {
            path.value.removeLast(path.value.count - (count - 1))
        }
        let (didPop, popContext) = _IndexActionBox { levels in
            if levels - 1 < path.value.count {
                path.value.removeLast(path.value.count - (levels - 1))
            }
        }.register(with: renderer)
        sui_navigation_commit(navigation, count, didPop, popContext)
        nodes.append(_Node(view: navigation, flexibleWidth: true, flexibleHeight: true))
    }
}

/// What one level of a `NavigationView` collects while it renders.
public final class _NavigationLevel {
    let path: _StateBox<[UInt64]>
    let depth: Int
    var parent: _NavigationLevel?
    var title: String?
    var trailingItem: [_Node]?
    /// Destinations of the links rendered on this level, by link key.
    var links: [UInt64: (inout [_Node], _RenderContext) -> Void] = [:]

    init(path: _StateBox<[UInt64]>, depth: Int) {
        self.path = path
        self.depth = depth
    }

    /// Shows `key`'s destination above this level.
    func push(_ key: UInt64) {
        path.value = Array(path.value.prefix(depth)) + [key]
    }
}

/// A button that pushes `destination` onto the enclosing `NavigationView`.
/// In a `List`, the whole row is tappable and shows a chevron.
public struct NavigationLink<Label: View, Destination: View>: View {
    let destination: Destination
    let label: Label

    public init(destination: Destination, @ViewBuilder label: () -> Label) {
        self.destination = destination
        self.label = label()
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let renderer = context.renderer
        let key = renderer.makeKey(0x4c49_4e4b_0000_0000)
        let destination = self.destination
        let level = context.navigation
        level?.links[key] = { nodes, context in
            destination._render(into: &nodes, context: context)
        }
        let action = _ActionBox { level?.push(key) }

        if context.isInList {
            var content: [_Node] = []
            label._render(into: &content, context: context)
            var node = _Node.stacked(content, axis: .vertical)
            node.navigationAction = action
            nodes.append(node)
            return
        }

        // Outside a list it looks like a button with a custom label.
        let (callback, actionContext) = action.register(with: renderer)
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

extension NavigationLink where Label == Text {
    public init(_ title: String, destination: Destination) {
        self.init(destination: destination) { Text(title) }
    }
}

/// A string literal used as a localization key. Strings are not localized
/// on this platform; the key is shown as is, with its interpolations.
public struct LocalizedStringKey: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String

    public init(_ key: String) {
        self.key = key
    }

    public init(stringLiteral value: String) {
        self.key = value
    }

    public init(stringInterpolation: StringInterpolation) {
        self.key = stringInterpolation.output
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var output = ""

        public init(literalCapacity: Int, interpolationCount: Int) {
            output.reserveCapacity(literalCapacity)
        }

        public mutating func appendLiteral(_ literal: String) {
            output += literal
        }

        public mutating func appendInterpolation(_ string: String) {
            output += string
        }

        public mutating func appendInterpolation<T: CustomStringConvertible>(_ value: T) {
            output += value.description
        }

        /// Supports `%d` and `%.Nf` specifiers.
        public mutating func appendInterpolation<T: BinaryFloatingPoint>(_ value: T, specifier: String) {
            output += LocalizedStringKey.format(Double(value), specifier: specifier)
        }

        public mutating func appendInterpolation<T: BinaryInteger>(_ value: T, specifier: String) {
            output += LocalizedStringKey.format(Double(value), specifier: specifier)
        }
    }

    /// Formats like `String(format:)` for `%d`, `%i` and `%.Nf`.
    static func format(_ value: Double, specifier: String) -> String {
        var decimals = 0
        let utf8 = Array(specifier.utf8)
        // %.Nf
        if utf8.count >= 4, utf8[0] == 0x25, utf8[1] == 0x2E, utf8.last == 0x66 {
            decimals = Int(String(decoding: utf8[2 ..< utf8.count - 1], as: UTF8.self)) ?? 6
        } else if utf8 == Array("%f".utf8) {
            decimals = 6
        }
        var scale = 1.0
        for _ in 0 ..< decimals {
            scale *= 10
        }
        let scaled = (value * scale).rounded()
        let sign = scaled < 0 ? "-" : ""
        let magnitude = scaled < 0 ? -scaled : scaled
        let whole = Int(magnitude / scale)
        guard decimals > 0 else {
            return sign + whole.description
        }
        let fraction = Int(magnitude - Double(whole) * scale).description
        let zeros = String(repeating: "0", count: max(0, decimals - fraction.utf8.count))
        return sign + whole.description + "." + zeros + fraction
    }
}

extension View {
    /// Sets the title of the navigation bar while this view is shown.
    public func navigationTitle(_ title: String) -> some View {
        _NavigationModifier(content: self) { level, _ in
            if level.title == nil { level.title = title }
        }
    }

    public func navigationTitle(_ title: LocalizedStringKey) -> some View {
        navigationTitle(title.key)
    }

    public func navigationBarTitle(_ title: String) -> some View {
        navigationTitle(title)
    }

    /// Puts `trailing` on the right of the navigation bar while this view is shown.
    public func navigationBarItems<Trailing: View>(trailing: Trailing) -> some View {
        _NavigationModifier(content: self) { level, context in
            guard level.trailingItem == nil else { return }
            let savedColor = context.foregroundColor
            context.foregroundColor = savedColor ?? .accentColor
            var items: [_Node] = []
            trailing._render(into: &items, context: context)
            context.foregroundColor = savedColor
            level.trailingItem = items
        }
    }
}

/// Renders `content`, then lets `update` set what the navigation bar shows.
/// Content renders first, so the innermost title wins, as in SwiftUI.
public struct _NavigationModifier<Content: View>: View {
    let content: Content
    let update: (_NavigationLevel, _RenderContext) -> Void

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        content._render(into: &nodes, context: context)
        if let level = context.navigation {
            let savedInList = context.isInList
            context.isInList = false
            update(level, context)
            context.isInList = savedInList
        }
    }
}
