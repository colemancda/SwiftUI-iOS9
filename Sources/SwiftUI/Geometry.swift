/// Lets app code written against SwiftUI use `CGFloat` without CoreGraphics.
public typealias CGFloat = Double

public enum Edge {
    case top, leading, bottom, trailing

    public struct Set: OptionSet {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let top = Set(rawValue: 1 << 0)
        public static let leading = Set(rawValue: 1 << 1)
        public static let bottom = Set(rawValue: 1 << 2)
        public static let trailing = Set(rawValue: 1 << 3)
        public static let horizontal: Set = [.leading, .trailing]
        public static let vertical: Set = [.top, .bottom]
        public static let all: Set = [.top, .leading, .bottom, .trailing]
    }
}

public enum HorizontalAlignment {
    case leading, center, trailing
}

public enum VerticalAlignment {
    case top, center, bottom
}

extension Double {
    /// Rounds to whole points for the backend.
    var points: Int {
        self < 0 ? -Int(-self + 0.5) : Int(self + 0.5)
    }
}

extension String {
    /// Calls `body` with a NUL-terminated UTF-8 copy of the string.
    func withUTF8CString<Result>(_ body: (UnsafePointer<CChar>) -> Result) -> Result {
        var bytes: [CChar] = []
        bytes.reserveCapacity(utf8.count + 1)
        for byte in utf8 {
            bytes.append(CChar(bitPattern: byte))
        }
        bytes.append(0)
        return bytes.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
