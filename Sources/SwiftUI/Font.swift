import CSwiftUIBackend

/// A system font. Text styles use iOS's default (Large) Dynamic Type sizes.
public struct Font: Equatable {
    public enum Weight: Equatable {
        case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black

        var backendValue: Int {
            switch self {
            case .ultraLight, .thin, .light, .regular: Int(SUIFontWeightRegular)
            case .medium: Int(SUIFontWeightMedium)
            case .semibold: Int(SUIFontWeightSemibold)
            case .bold, .heavy, .black: Int(SUIFontWeightBold)
            }
        }
    }

    let size: CGFloat
    let weight: Weight

    public static func system(size: CGFloat, weight: Weight = .regular) -> Font {
        Font(size: size, weight: weight)
    }

    public static var largeTitle: Font { Font(size: 34, weight: .regular) }
    public static var title: Font { Font(size: 28, weight: .regular) }
    public static var title2: Font { Font(size: 22, weight: .regular) }
    public static var title3: Font { Font(size: 20, weight: .regular) }
    public static var headline: Font { Font(size: 17, weight: .semibold) }
    public static var body: Font { Font(size: 17, weight: .regular) }
    public static var callout: Font { Font(size: 16, weight: .regular) }
    public static var subheadline: Font { Font(size: 15, weight: .regular) }
    public static var footnote: Font { Font(size: 13, weight: .regular) }
    public static var caption: Font { Font(size: 12, weight: .regular) }
    public static var caption2: Font { Font(size: 11, weight: .regular) }

    public func weight(_ weight: Weight) -> Font {
        Font(size: size, weight: weight)
    }

    public func bold() -> Font {
        weight(.bold)
    }
}
