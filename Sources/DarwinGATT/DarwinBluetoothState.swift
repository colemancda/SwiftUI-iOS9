//
//  DarwinBluetoothState.swift
//
//
//  Created by Alsey Coleman Miller on 10/31/26.
//

/// CoreBluetooth central state, same cases as GATT's `DarwinBluetoothState`.
public enum DarwinBluetoothState: Int, Sendable, CaseIterable {

    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

extension DarwinBluetoothState: CustomStringConvertible {

    public var description: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .resetting:
            return "Resetting"
        case .unsupported:
            return "Unsupported"
        case .unauthorized:
            return "Unauthorized"
        case .poweredOff:
            return "Powered Off"
        case .poweredOn:
            return "Powered On"
        }
    }
}
