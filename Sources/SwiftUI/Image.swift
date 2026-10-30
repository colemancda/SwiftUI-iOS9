import CSwiftUIBackend

/// An image. iOS 9 has no SF Symbols, so `Image(systemName:)` draws a
/// similar Unicode character, or nothing for symbols it doesn't know.
public struct Image: View {
    let glyph: String

    public init(systemName: String) {
        glyph = Image.glyph(forSystemName: systemName)
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        Text(verbatim: glyph)._render(into: &nodes, context: context)
    }

    public func symbolRenderingMode(_ mode: SymbolRenderingMode?) -> Image {
        self
    }

    public func renderingMode(_ mode: TemplateRenderingMode?) -> Image {
        self
    }

    static func glyph(forSystemName name: String) -> String {
        switch name {
        case "arrow.clockwise": return "↻"
        case "checkmark": return "✓"
        case "chevron.left": return "‹"
        case "chevron.right": return "›"
        case "cooktop", "cooktop.fill", "heater.vertical", "heater.vertical.fill": return "♨︎"
        case "cup.and.saucer", "cup.and.saucer.fill": return "☕︎"
        case "exclamationmark.triangle", "exclamationmark.triangle.fill": return "⚠︎"
        case "gear", "gearshape", "gearshape.fill": return "⚙︎"
        case "info.circle", "info.circle.fill": return "ⓘ"
        case "minus": return "−"
        case "play", "play.fill": return "▶︎"
        case "plus": return "+"
        case "power": return "⏻"
        case "star", "star.fill": return "★"
        case "stop", "stop.fill": return "■"
        case "thermometer", "thermometer.medium": return "🌡"
        case "wind": return "≋"
        case "xmark": return "✕"
        default: return ""
        }
    }
}

public enum SymbolRenderingMode {
    case monochrome, multicolor, hierarchical, palette
}

public enum TemplateRenderingMode {
    case template, original
}
