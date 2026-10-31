import CSwiftUIBackend

/// A labeled switch.
public struct Toggle<Label: View>: View {
    let isOn: Binding<Bool>
    let label: Label

    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self.isOn = isOn
        self.label = label()
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let isOn = self.isOn
        let (changed, changedContext) = _IndexActionBox { isOn.wrappedValue = $0 != 0 }
            .register(with: context.renderer)
        let control = sui_switch_create(isOn.wrappedValue ? 1 : 0, changed, changedContext)!
        nodes.append(_Node.labeled(label, control: control, context: context))
    }
}

extension Toggle where Label == Text {
    public init(_ title: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(title) }
    }
}

/// A labeled stepper for a floating-point value. Values are kept to
/// hundredths.
public struct Stepper<Label: View>: View {
    let value: () -> Double
    let setValue: (Double) -> Void
    let bounds: ClosedRange<Double>
    let step: Double
    let label: Label

    public init<V: BinaryFloatingPoint>(
        value: Binding<V>,
        in bounds: ClosedRange<V>,
        step: V.Stride = 1,
        @ViewBuilder label: () -> Label
    ) where V.Stride: BinaryFloatingPoint {
        self.value = { Double(value.wrappedValue) }
        self.setValue = { value.wrappedValue = V($0) }
        self.bounds = Double(bounds.lowerBound) ... Double(bounds.upperBound)
        self.step = Double(step)
        self.label = label()
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let setValue = self.setValue
        let (changed, changedContext) = _IndexActionBox { setValue(Double($0) / 100) }
            .register(with: context.renderer)
        let control = sui_stepper_create(
            hundredths(value()), hundredths(bounds.lowerBound), hundredths(bounds.upperBound), hundredths(step),
            changed, changedContext
        )!
        nodes.append(_Node.labeled(label, control: control, context: context))
    }
}

extension Stepper where Label == Text {
    public init<V: BinaryFloatingPoint>(
        _ title: String,
        value: Binding<V>,
        in bounds: ClosedRange<V>,
        step: V.Stride = 1
    ) where V.Stride: BinaryFloatingPoint {
        self.init(value: value, in: bounds, step: step) { Text(title) }
    }
}

/// A slider for a floating-point value, taking the width it is offered.
/// `onEditingChanged` is called with `false` when the user lets go.
public struct Slider: View {
    let value: () -> Double
    let setValue: (Double) -> Void
    let bounds: ClosedRange<Double>
    let step: Double
    let onEditingChanged: (Bool) -> Void

    public init<V: BinaryFloatingPoint>(
        value: Binding<V>,
        in bounds: ClosedRange<V> = 0 ... 1,
        step: V.Stride? = nil,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) where V.Stride: BinaryFloatingPoint {
        self.value = { Double(value.wrappedValue) }
        self.setValue = { value.wrappedValue = V($0) }
        self.bounds = Double(bounds.lowerBound) ... Double(bounds.upperBound)
        self.step = step.map { Double($0) } ?? 0
        self.onEditingChanged = onEditingChanged
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let setValue = self.setValue
        let onEditingChanged = self.onEditingChanged
        // The backend passes one context to both callbacks, so `ended` calls
        // the same box with a value no slider reports.
        let (changed, context_) = _IndexActionBox { value in
            if value == Int.min {
                onEditingChanged(false)
            } else {
                setValue(Double(value) / 100)
            }
        }.register(with: context.renderer)
        let ended: SUICallback = { context in
            MainActor.assumeIsolated {
                Unmanaged<_IndexActionBox>.fromOpaque(context!).takeUnretainedValue().action(Int.min)
            }
        }
        let control = sui_slider_create(
            hundredths(value()), hundredths(bounds.lowerBound), hundredths(bounds.upperBound), hundredths(step),
            changed, ended, context_
        )!
        if !context.isEnabled {
            sui_control_set_enabled(control, 0)
        }
        nodes.append(_Node(view: control, flexibleWidth: true))
    }
}

/// Picks one of the values tagged in its content, shown as a segmented
/// control whatever the style. Options are `Text` views with `tag(_:)`, whose
/// values must have the selection's type.
public struct Picker<Label: View, SelectionValue: Hashable, Content: View>: View {
    let selection: Binding<SelectionValue>
    let content: Content

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let options = _PickerOptions()
        let savedOptions = context.pickerOptions
        context.pickerOptions = options
        var ignored: [_Node] = []
        content._render(into: &ignored, context: context)
        context.pickerOptions = savedOptions

        // Tags have the selection's type; see `tag(_:)`.
        let tags = options.tags.map { unsafeDowncast($0, to: _TagBox<SelectionValue>.self).value }
        let selection = self.selection
        let selected = tags.firstIndex(of: selection.wrappedValue) ?? -1
        let (changed, changedContext) = _IndexActionBox { index in
            if tags.indices.contains(index) {
                selection.wrappedValue = tags[index]
            }
        }.register(with: context.renderer)
        let control = withCStrings(options.titles) { titles, count in
            sui_segmented_create(titles, count, selected, changed, changedContext)
        }!
        if !context.isEnabled {
            sui_control_set_enabled(control, 0)
        }
        nodes.append(_Node(view: control, flexibleWidth: true))
    }
}

extension Picker where Label == Text {
    public init(_ title: String, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.selection = selection
        self.content = content()
    }
}

/// Picker styles are accepted for compatibility; pickers are segmented.
public protocol PickerStyle {}

public struct SegmentedPickerStyle: PickerStyle {}
public struct MenuPickerStyle: PickerStyle {}
public struct WheelPickerStyle: PickerStyle {}
public struct InlinePickerStyle: PickerStyle {}
public struct DefaultPickerStyle: PickerStyle {}

extension PickerStyle where Self == SegmentedPickerStyle {
    public static var segmented: SegmentedPickerStyle { SegmentedPickerStyle() }
}

extension PickerStyle where Self == MenuPickerStyle {
    public static var menu: MenuPickerStyle { MenuPickerStyle() }
}

extension PickerStyle where Self == WheelPickerStyle {
    public static var wheel: WheelPickerStyle { WheelPickerStyle() }
}

extension PickerStyle where Self == InlinePickerStyle {
    public static var inline: InlinePickerStyle { InlinePickerStyle() }
}

extension PickerStyle where Self == DefaultPickerStyle {
    public static var automatic: DefaultPickerStyle { DefaultPickerStyle() }
}

extension View {
    public func pickerStyle<S: PickerStyle>(_ style: S) -> Self {
        self
    }

    /// The value a `Picker` selects for this view.
    public func tag<V: Hashable>(_ tag: V) -> some View {
        _TagModifier(content: self, tag: tag)
    }
}

/// Inside a `Picker`, adds an option titled with the content's text;
/// elsewhere, shows the content.
public struct _TagModifier<Content: View, V: Hashable>: View {
    let content: Content
    let tag: V

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        guard let options = context.pickerOptions else {
            content._render(into: &nodes, context: context)
            return
        }
        let sink = _TextSink()
        let savedSink = context.textSink
        context.textSink = sink
        var ignored: [_Node] = []
        content._render(into: &ignored, context: context)
        context.textSink = savedSink
        options.titles.append(sink.text)
        options.tags.append(_TagBox(tag))
    }
}

/// The options a `Picker` collects from its content.
public final class _PickerOptions {
    var titles: [String] = []
    var tags: [AnyObject] = []
}

final class _TagBox<V> {
    let value: V

    init(_ value: V) {
        self.value = value
    }
}

/// A spinning activity indicator.
public struct ProgressView: View {
    public init() {}

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        nodes.append(_Node(view: sui_activity_indicator_create()!))
    }
}

extension _Node {
    /// A row with the label on the leading side and the control on the trailing side.
    @MainActor
    static func labeled<Label: View>(_ label: Label, control: SUIViewRef, context: _RenderContext) -> _Node {
        if !context.isEnabled {
            sui_control_set_enabled(control, 0)
        }
        var children: [_Node] = []
        label._render(into: &children, context: context)
        children.append(_Node(view: sui_spacer_create(defaultSpacing.points)!, flexibleWidth: true, flexibleHeight: true, isSpacer: true))
        children.append(_Node(view: control))
        return .stacked(children, axis: .horizontal, alwaysWrap: true)
    }
}

/// Rounds to hundredths for the backend.
private func hundredths(_ value: Double) -> Int {
    (value * 100).points
}

/// Calls `body` with a C array of NUL-terminated copies of `strings`.
private func withCStrings<Result>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafePointer<CChar>?>?, Int) -> Result
) -> Result {
    let copies = strings.map { string -> UnsafeMutablePointer<CChar> in
        let utf8 = Array(string.utf8)
        let copy = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count + 1)
        for (index, byte) in utf8.enumerated() {
            copy[index] = CChar(bitPattern: byte)
        }
        copy[utf8.count] = 0
        return copy
    }
    defer { copies.forEach { $0.deallocate() } }
    let pointers = copies.map { UnsafePointer<CChar>?(UnsafePointer($0)) }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress, $0.count) }
}
