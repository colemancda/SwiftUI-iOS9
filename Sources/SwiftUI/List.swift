import CSwiftUIBackend

/// A scrolling list with one row per child view, in the plain iOS 9 table
/// style. Rows made by `NavigationLink` are tappable and show a chevron.
public struct List<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let renderer = context.renderer
        let list = sui_list_create(UInt(truncatingIfNeeded: renderer.makeKey(0x4c49_5354_0000_0000)))!

        let savedInList = context.isInList
        context.isInList = true
        var rows: [_Node] = []
        content._render(into: &rows, context: context)
        context.isInList = savedInList

        for row in rows {
            if let action = row.navigationAction {
                let (callback, actionContext) = action.register(with: renderer)
                sui_list_add_row(list, row.view, 1, callback, actionContext)
            } else {
                sui_list_add_row(list, row.view, 0, nil, nil)
            }
        }
        nodes.append(_Node(view: list, flexibleWidth: true, flexibleHeight: true))
    }
}

extension List {
    /// One row per element of `data`.
    public init<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == ForEach<Data, RowContent>, Data.Element: Identifiable {
        self.content = ForEach(data, content: rowContent)
    }
}
