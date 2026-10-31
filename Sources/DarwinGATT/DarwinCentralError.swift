//
//  DarwinCentralError.swift
//
//
//  Created by Alsey Coleman Miller on 10/31/26.
//

import CDarwinGATT
import GATT

/// Errors from CoreBluetooth that have no `CentralError` equivalent.
public enum DarwinCentralError: Error, Equatable, Sendable {

    /// ATT error from the peripheral.
    case att(UInt8)

    /// `CBError` code.
    case coreBluetooth(Int)

    /// Any other error.
    case other
}

extension DarwinCentralError: CustomStringConvertible {

    public var description: String {
        switch self {
        case let .att(code):
            return "ATT error \(code)"
        case let .coreBluetooth(code):
            return "CoreBluetooth error \(code)"
        case .other:
            return "Bluetooth error"
        }
    }
}

internal extension DarwinCentral {

    /// The error for a backend error code, or `nil` for success.
    static func error(_ code: Int, uuid: BluetoothUUID? = nil) -> Error? {
        switch code {
        case Int(DGErrorNone):
            return nil
        case Int(DGErrorUnknownPeripheral):
            return CentralError.unknownPeripheral
        case Int(DGErrorInvalidAttribute):
            return CentralError.invalidAttribute(uuid ?? .bit16(0))
        case Int(DGErrorDisconnected):
            return CentralError.disconnected
        case Int(DGErrorATT) ..< Int(DGErrorATT) + 0x100:
            return DarwinCentralError.att(UInt8(code & 0xFF))
        case Int(DGErrorCoreBluetooth) ..< Int(DGErrorCoreBluetooth) + 0x100:
            return DarwinCentralError.coreBluetooth(code & 0xFF)
        default:
            return DarwinCentralError.other
        }
    }
}
