import CSwiftUIBackend

/// The default spacing between stack children, close to SwiftUI's.
let defaultSpacing: CGFloat = 8

enum Axis {
    case horizontal, vertical

    var backendValue: Int {
        self == .vertical ? Int(SUIAxisVertical) : Int(SUIAxisHorizontal)
    }
}

extension _Node {
    /// Puts `children` in a UIStackView. A single child is returned as is.
    static func stacked(
        _ children: [_Node],
        axis: Axis,
        spacing: CGFloat = defaultSpacing,
        alignment: Int = Int(SUIAlignmentCenter),
        alwaysWrap: Bool = false
    ) -> _Node {
        if children.count == 1 && !alwaysWrap { return children[0] }
        let stack = sui_stack_create(axis.backendValue, spacing.points, alignment)!
        var node = _Node(view: stack)
        for child in children {
            let stretchesAcross = axis == .vertical ? child.flexibleWidth : child.flexibleHeight
            sui_stack_add(stack, child.view, stretchesAcross && !child.isSpacer ? 1 : 0)
            // Spacers make a stack flexible along its axis only.
            switch axis {
            case .vertical:
                node.flexibleHeight = node.flexibleHeight || child.flexibleHeight
                node.flexibleWidth = node.flexibleWidth || (child.flexibleWidth && !child.isSpacer)
            case .horizontal:
                node.flexibleWidth = node.flexibleWidth || child.flexibleWidth
                node.flexibleHeight = node.flexibleHeight || (child.flexibleHeight && !child.isSpacer)
            }
        }
        return node
    }
}

public struct VStack<Content: View>: View {
    let alignment: HorizontalAlignment
    let spacing: CGFloat?
    let content: Content

    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        var children: [_Node] = []
        content._render(into: &children, context: context)
        let backendAlignment: Int
        switch alignment {
        case .leading: backendAlignment = SUIAlignmentLeading
        case .center: backendAlignment = SUIAlignmentCenter
        case .trailing: backendAlignment = SUIAlignmentTrailing
        }
        nodes.append(.stacked(children, axis: .vertical, spacing: spacing ?? defaultSpacing, alignment: backendAlignment, alwaysWrap: true))
    }
}

public struct HStack<Content: View>: View {
    let alignment: VerticalAlignment
    let spacing: CGFloat?
    let content: Content

    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        var children: [_Node] = []
        content._render(into: &children, context: context)
        let backendAlignment: Int
        switch alignment {
        case .top: backendAlignment = SUIAlignmentLeading
        case .center: backendAlignment = SUIAlignmentCenter
        case .bottom: backendAlignment = SUIAlignmentTrailing
        }
        nodes.append(.stacked(children, axis: .horizontal, spacing: spacing ?? defaultSpacing, alignment: backendAlignment, alwaysWrap: true))
    }
}

/// Takes up the free space along its stack's axis.
public struct Spacer: View {
    let minLength: CGFloat?

    public init(minLength: CGFloat? = nil) {
        self.minLength = minLength
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let spacer = sui_spacer_create((minLength ?? defaultSpacing).points)!
        nodes.append(_Node(view: spacer, flexibleWidth: true, flexibleHeight: true, isSpacer: true))
    }
}

/// Renders `content` once per element of `data`.
///
/// Each element's state and navigation links follow its `id` for
/// `Identifiable` data, and its position for ranges.
public struct ForEach<Data: RandomAccessCollection, Content: View>: View {
    let data: Data
    let content: (Data.Element) -> Content
    let identity: ((Data.Element) -> Int)?

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        for element in data {
            let scope = identity.map { context.renderer.enterScope(identity: $0(element)) }
                ?? context.renderer.enterScope()
            content(element)._render(into: &nodes, context: context)
            context.renderer.exitScope(scope)
        }
    }
}

extension ForEach where Data == Range<Int> {
    public init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> Content) {
        self.data = data
        self.content = content
        self.identity = nil
    }
}

extension ForEach where Data.Element: Identifiable {
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
        self.identity = { $0.id.hashValue }
    }
}
