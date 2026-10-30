import CSwiftUIBackend

/// An sRGB color. As a view, it fills the space it is offered.
public struct Color: View, Equatable {
    /// 0xRRGGBBAA
    let rgba: UInt32

    init(rgba: UInt32) {
        self.rgba = rgba
    }

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        func component(_ value: Double) -> UInt32 {
            UInt32(Swift.max(0, Swift.min(255, (value * 255).points)))
        }
        rgba = component(red) << 24 | component(green) << 16 | component(blue) << 8 | component(opacity)
    }

    public init(white: Double, opacity: Double = 1) {
        self.init(red: white, green: white, blue: white, opacity: opacity)
    }

    public func opacity(_ opacity: Double) -> Color {
        let alpha = UInt32(Swift.max(0, Swift.min(255, (Double(rgba & 0xff) * opacity).points)))
        return Color(rgba: rgba & 0xffff_ff00 | alpha)
    }

    // iOS system colors.
    public static var black: Color { Color(rgba: 0x0000_00ff) }
    public static var white: Color { Color(rgba: 0xffff_ffff) }
    public static var gray: Color { Color(rgba: 0x8e8e_93ff) }
    public static var red: Color { Color(rgba: 0xff3b_30ff) }
    public static var orange: Color { Color(rgba: 0xff95_00ff) }
    public static var yellow: Color { Color(rgba: 0xffcc_00ff) }
    public static var green: Color { Color(rgba: 0x34c7_59ff) }
    public static var mint: Color { Color(rgba: 0x00c7_beff) }
    public static var teal: Color { Color(rgba: 0x30b0_c7ff) }
    public static var cyan: Color { Color(rgba: 0x32ad_e6ff) }
    public static var blue: Color { Color(rgba: 0x007a_ffff) }
    public static var indigo: Color { Color(rgba: 0x5856_d6ff) }
    public static var purple: Color { Color(rgba: 0xaf52_deff) }
    public static var pink: Color { Color(rgba: 0xff2d_55ff) }
    public static var brown: Color { Color(rgba: 0xa286_7eff) }
    public static var clear: Color { Color(rgba: 0x0000_0000) }
    public static var primary: Color { .black }
    public static var secondary: Color { .gray }
    public static var accentColor: Color { .blue }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let view = sui_color_view_create(UInt(rgba))!
        nodes.append(_Node(view: view, flexibleWidth: true, flexibleHeight: true))
    }
}
