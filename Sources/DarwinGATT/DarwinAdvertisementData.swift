//
//  DarwinAdvertisementData.swift
//
//
//  Created by Alsey Coleman Miller on 10/31/26.
//

import CDarwinGATT
import Bluetooth
import GATT

/// CoreBluetooth advertisement data.
public struct DarwinAdvertisementData: AdvertisementData {

    public typealias Data = [UInt8]

    public let localName: String?

    public let manufacturerData: ManufacturerSpecificData<[UInt8]>?

    public let txPowerLevel: Double?

    public let serviceData: [BluetoothUUID: [UInt8]]?

    public let serviceUUIDs: [BluetoothUUID]?

    public let solicitedServiceUUIDs: [BluetoothUUID]?

    /// Service UUIDs found in the overflow area, on devices advertising in the background.
    public let overflowServiceUUIDs: [BluetoothUUID]?

    internal let isConnectable: Bool?
}

internal extension DarwinAdvertisementData {

    init(_ advertisement: DGAdvertisement) {
        func uuids(_ strings: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int) -> [BluetoothUUID]? {
            guard let strings, count > 0 else {
                return nil
            }
            return (0 ..< count).compactMap { BluetoothUUID(cString: strings[$0]) }
        }
        self.localName = advertisement.name.map { String(cString: $0) }
        if let bytes = advertisement.manufacturer_data, advertisement.manufacturer_data_length > 0 {
            self.manufacturerData = ManufacturerSpecificData(
                data: Array(UnsafeBufferPointer(start: bytes, count: advertisement.manufacturer_data_length))
            )
        } else {
            self.manufacturerData = nil
        }
        self.txPowerLevel = advertisement.has_tx_power_level != 0 ? Double(advertisement.tx_power_level) : nil
        self.serviceUUIDs = uuids(advertisement.service_uuids, advertisement.service_uuid_count)
        self.overflowServiceUUIDs = uuids(advertisement.overflow_service_uuids, advertisement.overflow_service_uuid_count)
        self.solicitedServiceUUIDs = uuids(advertisement.solicited_service_uuids, advertisement.solicited_service_uuid_count)
        if advertisement.service_data_count > 0 {
            var serviceData = [BluetoothUUID: [UInt8]]()
            for index in 0 ..< advertisement.service_data_count {
                guard let uuid = BluetoothUUID(cString: advertisement.service_data_uuids[index]) else {
                    continue
                }
                let length = advertisement.service_data_lengths[index]
                serviceData[uuid] = Array(UnsafeBufferPointer(start: advertisement.service_data[index], count: length))
            }
            self.serviceData = serviceData
        } else {
            self.serviceData = nil
        }
        self.isConnectable = advertisement.is_connectable < 0 ? nil : advertisement.is_connectable != 0
    }
}

internal extension BluetoothUUID {

    /// Parses a CoreBluetooth `UUIDString`.
    init?(cString: UnsafePointer<CChar>?) {
        guard let cString else {
            return nil
        }
        self.init(rawValue: String(cString: cString))
    }
}
