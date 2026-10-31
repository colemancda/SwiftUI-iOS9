//
//  DarwinCentral.swift
//
//
//  Created by Alsey Coleman Miller on 10/31/26.
//

import _Concurrency
import CDarwinGATT
import Bluetooth
import GATT

/// GATT central for iOS 9 in Embedded Swift, backed by CoreBluetooth.
///
/// Mirrors GATT's `DarwinCentral`. CoreBluetooth runs on the main queue,
/// like Swift tasks, so state is only touched from the main thread.
/// Create only one; it lives until the app exits.
public final class DarwinCentral: CentralManager, @unchecked Sendable {

    public typealias Advertisement = DarwinAdvertisementData

    public typealias State = DarwinBluetoothState

    public typealias AttributeID = UInt

    public typealias Data = [UInt8]

    public typealias Service = GATT.Service<Peripheral, AttributeID>

    public typealias Characteristic = GATT.Characteristic<Peripheral, AttributeID>

    public typealias Descriptor = GATT.Descriptor<Peripheral, AttributeID>

    // MARK: - Properties

    public var log: (@Sendable (String) -> ())?

    public let options: Options

    public var state: DarwinBluetoothState {
        get async {
            DarwinBluetoothState(rawValue: dg_central_state()) ?? .unknown
        }
    }

    /// Scanned peripherals, and whether each is connected.
    public var peripherals: [Peripheral: Bool] {
        get async {
            var peripherals = [Peripheral: Bool]()
            for peripheral in discovered {
                peripherals[peripheral] = peripheral.id.withCString { dg_is_connected($0) } == 1
            }
            return peripherals
        }
    }

    private var discovered = Set<Peripheral>()

    private var scan: (id: UInt, continuation: AsyncIndefiniteStream<ScanData<Peripheral, Advertisement>>.Continuation)?

    private var scanCount: UInt = 0

    private var notifications = [AttributeID: (peripheral: Peripheral, continuation: AsyncIndefiniteStream<Data>.Continuation)]()

    // MARK: - Initialization

    public init(options: Options = Options()) {
        self.options = options
        var events = DGCentralEvents(
            state_changed: { context, state in
                DarwinCentral.from(context).log?("State: \(DarwinBluetoothState(rawValue: state) ?? .unknown)")
            },
            discovered: { context, advertisement in
                DarwinCentral.from(context).discovered(advertisement!.pointee)
            },
            disconnected: { context, peripheral, error in
                DarwinCentral.from(context).disconnected(Peripheral(id: String(cString: peripheral!)), error: error)
            },
            notified: { context, characteristic, bytes, length in
                DarwinCentral.from(context).notified(characteristic, Array(UnsafeBufferPointer(start: bytes, count: length)))
            }
        )
        // CoreBluetooth keeps calling back for the life of the app.
        dg_central_start(options.showPowerAlert ? 1 : 0, &events, Unmanaged.passRetained(self).toOpaque())
    }

    // MARK: - Scanning

    /// Scans for all peripherals.
    public func scan(
        filterDuplicates: Bool = true
    ) async throws -> AsyncCentralScan<DarwinCentral> {
        scan(with: [], filterDuplicates: filterDuplicates)
    }

    /// Scans for peripherals advertising any of the services, or all peripherals if `services` is empty.
    public func scan(
        with services: Set<BluetoothUUID>,
        filterDuplicates: Bool = true
    ) -> AsyncCentralScan<DarwinCentral> {
        scanCount += 1
        let id = scanCount
        return AsyncCentralScan(onTermination: { [unowned(unsafe) self] in
            // A newer scan may have replaced this one.
            guard self.scan?.id == id else { return }
            self.scan = nil
            dg_central_stop_scan()
            self.log?("Discovered \(self.discovered.count) peripherals")
        }) { continuation in
            self.scan?.continuation.finish(throwing: CancellationError())
            self.scan = (id, continuation)
            withCStrings(services.map { $0.rawValue }) { list, count in
                dg_central_scan(list, count, filterDuplicates ? 0 : 1)
            }
        }
    }

    // MARK: - Connection

    public func connect(to peripheral: Peripheral) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = Callback<Int> { error in
                continuation.resume(error: error)
            }.retained
            peripheral.id.withCString {
                dg_connect($0, Thunk.status, context)
            }
        }
    }

    public func disconnect(_ peripheral: Peripheral) async {
        peripheral.id.withCString { dg_disconnect($0) }
    }

    public func disconnectAll() async {
        for (peripheral, isConnected) in await peripherals where isConnected {
            await disconnect(peripheral)
        }
    }

    // MARK: - Discovery

    public func discoverServices(
        _ services: Set<BluetoothUUID>,
        for peripheral: Peripheral
    ) async throws -> [Service] {
        try await withCheckedThrowingContinuation { continuation in
            let context = Callback<(Int, UnsafeBufferPointer<DGAttribute>)> { error, attributes in
                continuation.resume(error: error) {
                    attributes.map {
                        Service(id: $0.handle, uuid: BluetoothUUID(cString: $0.uuid) ?? .bit16(0), peripheral: peripheral, isPrimary: $0.flags != 0)
                    }
                }
            }.retained
            withCStrings(services.map { $0.rawValue }) { list, count in
                peripheral.id.withCString {
                    dg_discover_services($0, list, count, Thunk.attributes, context)
                }
            }
        }
    }

    public func discoverCharacteristics(
        _ characteristics: Set<BluetoothUUID>,
        for service: Service
    ) async throws -> [Characteristic] {
        try await withCheckedThrowingContinuation { continuation in
            let context = Callback<(Int, UnsafeBufferPointer<DGAttribute>)> { error, attributes in
                continuation.resume(error: error, uuid: service.uuid) {
                    attributes.map {
                        Characteristic(
                            id: $0.handle,
                            uuid: BluetoothUUID(cString: $0.uuid) ?? .bit16(0),
                            peripheral: service.peripheral,
                            properties: CharacteristicProperties(rawValue: UInt8(truncatingIfNeeded: $0.flags))
                        )
                    }
                }
            }.retained
            withCStrings(characteristics.map { $0.rawValue }) { list, count in
                dg_discover_characteristics(service.id, list, count, Thunk.attributes, context)
            }
        }
    }

    public func discoverDescriptors(
        for characteristic: Characteristic
    ) async throws -> [Descriptor] {
        try await withCheckedThrowingContinuation { continuation in
            let context = Callback<(Int, UnsafeBufferPointer<DGAttribute>)> { error, attributes in
                continuation.resume(error: error, uuid: characteristic.uuid) {
                    attributes.map {
                        Descriptor(id: $0.handle, uuid: BluetoothUUID(cString: $0.uuid) ?? .bit16(0), peripheral: characteristic.peripheral)
                    }
                }
            }.retained
            dg_discover_descriptors(characteristic.id, Thunk.attributes, context)
        }
    }

    // MARK: - Values

    public func readValue(for characteristic: Characteristic) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let context = Callback<(Int, [UInt8])> { error, value in
                continuation.resume(error: error, uuid: characteristic.uuid) { value }
            }.retained
            dg_read_characteristic(characteristic.id, Thunk.data, context)
        }
    }

    public func writeValue(
        _ data: Data,
        for characteristic: Characteristic,
        withResponse: Bool
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = Callback<Int> { error in
                continuation.resume(error: error, uuid: characteristic.uuid)
            }.retained
            data.withUnsafeBufferPointer {
                dg_write_characteristic(characteristic.id, $0.baseAddress, $0.count, withResponse ? 1 : 0, Thunk.status, context)
            }
        }
    }

    public func readValue(for descriptor: Descriptor) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let context = Callback<(Int, [UInt8])> { error, value in
                continuation.resume(error: error, uuid: descriptor.uuid) { value }
            }.retained
            dg_read_descriptor(descriptor.id, Thunk.data, context)
        }
    }

    public func writeValue(_ data: Data, for descriptor: Descriptor) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = Callback<Int> { error in
                continuation.resume(error: error, uuid: descriptor.uuid)
            }.retained
            data.withUnsafeBufferPointer {
                dg_write_descriptor(descriptor.id, $0.baseAddress, $0.count, Thunk.status, context)
            }
        }
    }

    public func notify(
        for characteristic: Characteristic
    ) async throws -> AsyncCentralNotifications<DarwinCentral> {
        let id = characteristic.id
        let stream = AsyncCentralNotifications<DarwinCentral>(onTermination: { [unowned(unsafe) self] in
            guard self.notifications.removeValue(forKey: id) != nil else { return }
            dg_set_notify(id, 0, Thunk.ignore, nil)
        }) { continuation in
            self.notifications[id] = (characteristic.peripheral, continuation)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = Callback<Int> { error in
                continuation.resume(error: error, uuid: characteristic.uuid)
            }.retained
            dg_set_notify(id, 1, Thunk.status, context)
        }
        return stream
    }

    // MARK: - Peripheral Info

    public func maximumTransmissionUnit(for peripheral: Peripheral) async throws -> MaximumTransmissionUnit {
        let length = peripheral.id.withCString { dg_maximum_write_length($0) }
        guard length > 0 else {
            throw CentralError.disconnected
        }
        // The ATT header takes 3 bytes.
        return MaximumTransmissionUnit(rawValue: UInt16(clamping: length + 3)) ?? .default
    }

    public func rssi(for peripheral: Peripheral) async throws -> RSSI {
        try await withCheckedThrowingContinuation { continuation in
            let context = Callback<(Int, Int)> { error, value in
                continuation.resume(error: error) { RSSI(rawValue: Int8(clamping: value)) ?? RSSI(rawValue: -127)! }
            }.retained
            peripheral.id.withCString {
                dg_read_rssi($0, Thunk.value, context)
            }
        }
    }
}

// MARK: - Supporting Types

public extension DarwinCentral {

    /// A peripheral, identified by its CoreBluetooth UUID string.
    struct Peripheral: Peer, Sendable, Identifiable, CustomStringConvertible {

        public let id: String

        public var description: String {
            id
        }
    }

    struct Options: Sendable {

        /// Whether iOS warns the user if Bluetooth is off when the central starts.
        public let showPowerAlert: Bool

        public init(showPowerAlert: Bool = false) {
            self.showPowerAlert = showPowerAlert
        }
    }
}

// MARK: - Events

private extension DarwinCentral {

    static func from(_ context: UnsafeMutableRawPointer?) -> DarwinCentral {
        Unmanaged<DarwinCentral>.fromOpaque(context!).takeUnretainedValue()
    }

    func discovered(_ event: DGAdvertisement) {
        let peripheral = Peripheral(id: String(cString: event.peripheral))
        let advertisement = DarwinAdvertisementData(event)
        discovered.insert(peripheral)
        let scanData = ScanData(
            peripheral: peripheral,
            date: UInt64(dg_time_milliseconds()),
            rssi: Double(event.rssi),
            advertisementData: advertisement,
            isConnectable: advertisement.isConnectable ?? false
        )
        scan?.continuation.yield(scanData)
    }

    func disconnected(_ peripheral: Peripheral, error: Int) {
        log?("Disconnected \(peripheral)")
        for (id, notification) in notifications where notification.peripheral == peripheral {
            notifications[id] = nil
            notification.continuation.finish(throwing: CentralError.disconnected)
        }
    }

    func notified(_ characteristic: AttributeID, _ value: [UInt8]) {
        notifications[characteristic]?.continuation.yield(value)
    }
}

// MARK: - Callbacks

/// A Swift closure passed to the backend as a callback's context.
private final class Callback<Arguments> {

    let body: (Arguments) -> Void

    init(_ body: @escaping (Arguments) -> Void) {
        self.body = body
    }

    /// The context to pass; the callback releases it.
    var retained: UnsafeMutableRawPointer {
        Unmanaged.passRetained(self).toOpaque()
    }

    static func call(_ context: UnsafeMutableRawPointer?, _ arguments: Arguments) {
        Unmanaged<Callback<Arguments>>.fromOpaque(context!).takeRetainedValue().body(arguments)
    }
}

/// C callbacks that call the `Callback` in their context.
private enum Thunk {

    static let status: DGCallback = { context, error in
        Callback<Int>.call(context, error)
    }

    static let value: DGValueCallback = { context, error, value in
        Callback<(Int, Int)>.call(context, (error, value))
    }

    static let data: DGDataCallback = { context, error, bytes, length in
        let value = bytes.map { Array(UnsafeBufferPointer(start: $0, count: length)) } ?? []
        Callback<(Int, [UInt8])>.call(context, (error, value))
    }

    static let attributes: DGAttributesCallback = { context, error, attributes, count in
        Callback<(Int, UnsafeBufferPointer<DGAttribute>)>.call(context, (error, UnsafeBufferPointer(start: attributes, count: count)))
    }

    static let ignore: DGCallback = { _, _ in }
}

private extension CheckedContinuation where E == Error {

    /// Resumes with the error for `code`, or else the result of `value`.
    func resume(error code: Int, uuid: BluetoothUUID? = nil, _ value: () -> T) {
        if let error = DarwinCentral.error(code, uuid: uuid) {
            resume(throwing: error)
        } else {
            resume(returning: value())
        }
    }
}

private extension CheckedContinuation where T == Void, E == Error {

    func resume(error code: Int, uuid: BluetoothUUID? = nil) {
        resume(error: code, uuid: uuid) { () }
    }
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
    return pointers.withUnsafeBufferPointer {
        body($0.baseAddress, $0.count)
    }
}
