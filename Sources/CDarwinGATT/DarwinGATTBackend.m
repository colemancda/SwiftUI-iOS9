// CoreBluetooth implementation of DarwinGATTBackend.h for iOS 9.

#import <CoreBluetooth/CoreBluetooth.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>
#import "DarwinGATTBackend.h"

@interface DGDelegate : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@end

static CBCentralManager *DGCentral;
static DGDelegate *DGCentralDelegate;
static DGCentralEvents DGEvents;
static void *DGEventsContext;

/// Peripherals seen so far, by UUID string. CoreBluetooth requires keeping them.
static NSMutableDictionary<NSString *, CBPeripheral *> *DGPeripherals;
/// Attributes by handle - 1, and handles by attribute.
static NSMutableArray<CBAttribute *> *DGAttributes;
static NSMapTable<CBAttribute *, NSNumber *> *DGHandles;

typedef void (^DGCompletion)(NSError *error);

/// Completions waiting for a delegate call, by operation key, in order.
static NSMutableDictionary<NSString *, NSMutableArray<DGCompletion> *> *DGPending;
/// The peripheral each pending operation key belongs to.
static NSMutableDictionary<NSString *, NSString *> *DGPendingPeripheral;

#pragma mark - Helpers

static NSString *const DGBackendErrorDomain = @"DarwinGATTBackend";

static long DGErrorCode(NSError *error) {
    if (!error) return DGErrorNone;
    if ([error.domain isEqualToString:DGBackendErrorDomain]) return error.code;
    if ([error.domain isEqualToString:CBATTErrorDomain]) return DGErrorATT | (error.code & 0xFF);
    if ([error.domain isEqualToString:CBErrorDomain]) return DGErrorCoreBluetooth | (error.code & 0xFF);
    return DGErrorOther;
}

static NSError *DGError(long code) {
    return [NSError errorWithDomain:DGBackendErrorDomain code:code userInfo:nil];
}

static NSString *DGString(const char *utf8) {
    return utf8 ? [NSString stringWithUTF8String:utf8] : nil;
}

static NSArray<CBUUID *> *DGUUIDs(const char *const *strings, long count) {
    if (count <= 0) return nil;
    NSMutableArray *uuids = [NSMutableArray arrayWithCapacity:count];
    for (long i = 0; i < count; i++) {
        [uuids addObject:[CBUUID UUIDWithString:DGString(strings[i])]];
    }
    return uuids;
}

static unsigned long DGHandle(CBAttribute *attribute) {
    NSNumber *handle = [DGHandles objectForKey:attribute];
    if (!handle) {
        [DGAttributes addObject:attribute];
        handle = @(DGAttributes.count);
        [DGHandles setObject:handle forKey:attribute];
    }
    return handle.unsignedLongValue;
}

static id DGFindAttribute(unsigned long handle, Class kind) {
    if (handle == 0 || handle > DGAttributes.count) return nil;
    CBAttribute *attribute = DGAttributes[handle - 1];
    return [attribute isKindOfClass:kind] ? attribute : nil;
}

static CBPeripheral *DGPeripheralOf(id attribute) {
    if ([attribute isKindOfClass:[CBService class]]) return [(CBService *)attribute peripheral];
    if ([attribute isKindOfClass:[CBCharacteristic class]]) return [(CBCharacteristic *)attribute service].peripheral;
    if ([attribute isKindOfClass:[CBDescriptor class]]) return [(CBDescriptor *)attribute characteristic].service.peripheral;
    return nil;
}

static NSString *DGKey(NSString *operation, id subject) {
    return [NSString stringWithFormat:@"%@:%@", operation, subject];
}

static void DGEnqueue(CBPeripheral *peripheral, NSString *key, DGCompletion completion) {
    NSMutableArray *queue = DGPending[key];
    if (!queue) {
        queue = [NSMutableArray array];
        DGPending[key] = queue;
        DGPendingPeripheral[key] = peripheral.identifier.UUIDString;
    }
    [queue addObject:[completion copy]];
}

/// Completes the oldest operation waiting on `key`. Returns NO if none was.
static BOOL DGComplete(NSString *key, NSError *error) {
    NSMutableArray<DGCompletion> *queue = DGPending[key];
    if (queue.count == 0) return NO;
    DGCompletion completion = queue.firstObject;
    [queue removeObjectAtIndex:0];
    if (queue.count == 0) {
        [DGPending removeObjectForKey:key];
        [DGPendingPeripheral removeObjectForKey:key];
    }
    completion(error);
    return YES;
}

/// Fails every operation waiting on `peripheral`.
static void DGFailAll(NSString *peripheral, NSError *error) {
    for (NSString *key in [DGPendingPeripheral allKeysForObject:peripheral]) {
        while (DGComplete(key, error)) {}
    }
}

/// Calls `done` with a C array of `attributes`.
static void DGReportAttributes(NSArray<CBAttribute *> *attributes, NSError *error,
                               DGAttributesCallback done, void *context) {
    if (error) {
        done(context, DGErrorCode(error), NULL, 0);
        return;
    }
    NSUInteger count = attributes.count;
    DGAttribute *list = calloc(count > 0 ? count : 1, sizeof(DGAttribute));
    for (NSUInteger i = 0; i < count; i++) {
        CBAttribute *attribute = attributes[i];
        list[i].handle = DGHandle(attribute);
        list[i].uuid = attribute.UUID.UUIDString.UTF8String;
        if ([attribute isKindOfClass:[CBCharacteristic class]]) {
            list[i].flags = [(CBCharacteristic *)attribute properties];
        } else if ([attribute isKindOfClass:[CBService class]]) {
            list[i].flags = [(CBService *)attribute isPrimary] ? 1 : 0;
        }
    }
    done(context, DGErrorNone, list, count);
    free(list);
}

static void DGReportData(NSData *data, NSError *error, DGDataCallback done, void *context) {
    if (error) {
        done(context, DGErrorCode(error), NULL, 0);
    } else {
        done(context, DGErrorNone, data.bytes, data.length);
    }
}

/// Descriptor values can be NSData, NSString or NSNumber.
static NSData *DGDescriptorData(id value) {
    if ([value isKindOfClass:[NSData class]]) return value;
    if ([value isKindOfClass:[NSString class]]) return [value dataUsingEncoding:NSUTF8StringEncoding];
    if ([value isKindOfClass:[NSNumber class]]) {
        uint16_t number = CFSwapInt16HostToLittle([value unsignedShortValue]);
        return [NSData dataWithBytes:&number length:sizeof(number)];
    }
    return [NSData data];
}

#pragma mark - Delegate

@implementation DGDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (DGEvents.state_changed) DGEvents.state_changed(DGEventsContext, central.state);
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    NSString *identifier = peripheral.identifier.UUIDString;
    if (!DGPeripherals[identifier]) {
        peripheral.delegate = DGCentralDelegate;
        DGPeripherals[identifier] = peripheral;
    }
    if (!DGEvents.discovered) return;

    DGAdvertisement advertisement = {0};
    advertisement.peripheral = identifier.UTF8String;
    advertisement.name = [advertisementData[CBAdvertisementDataLocalNameKey] UTF8String];
    advertisement.rssi = RSSI.longValue;
    NSNumber *connectable = advertisementData[CBAdvertisementDataIsConnectable];
    advertisement.is_connectable = connectable ? connectable.boolValue : -1;
    NSData *manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey];
    advertisement.manufacturer_data = manufacturerData.bytes;
    advertisement.manufacturer_data_length = manufacturerData.length;
    NSNumber *txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey];
    advertisement.has_tx_power_level = txPower != nil;
    advertisement.tx_power_level = txPower.longValue;

    // The C strings live as long as these arrays, which outlive the callback.
    NSArray<CBUUID *> *(^uuids)(NSString *) = ^(NSString *key) {
        return (NSArray<CBUUID *> *)advertisementData[key] ?: @[];
    };
    NSArray *services = uuids(CBAdvertisementDataServiceUUIDsKey);
    NSArray *overflow = uuids(CBAdvertisementDataOverflowServiceUUIDsKey);
    NSArray *solicited = uuids(CBAdvertisementDataSolicitedServiceUUIDsKey);
    NSDictionary<CBUUID *, NSData *> *serviceData = advertisementData[CBAdvertisementDataServiceDataKey] ?: @{};
    NSArray<CBUUID *> *serviceDataUUIDs = serviceData.allKeys;

    NSUInteger total = services.count + overflow.count + solicited.count + serviceDataUUIDs.count;
    const char **strings = calloc(total > 0 ? total : 1, sizeof(char *));
    const unsigned char **data = calloc(serviceDataUUIDs.count > 0 ? serviceDataUUIDs.count : 1, sizeof(char *));
    long *lengths = calloc(serviceDataUUIDs.count > 0 ? serviceDataUUIDs.count : 1, sizeof(long));
    __block const char **next = strings;
    const char *const *(^fill)(NSArray<CBUUID *> *) = ^(NSArray<CBUUID *> *list) {
        const char **start = next;
        for (CBUUID *uuid in list) *next++ = uuid.UUIDString.UTF8String;
        return (const char *const *)start;
    };
    advertisement.service_uuids = fill(services);
    advertisement.service_uuid_count = services.count;
    advertisement.overflow_service_uuids = fill(overflow);
    advertisement.overflow_service_uuid_count = overflow.count;
    advertisement.solicited_service_uuids = fill(solicited);
    advertisement.solicited_service_uuid_count = solicited.count;
    advertisement.service_data_uuids = fill(serviceDataUUIDs);
    for (NSUInteger i = 0; i < serviceDataUUIDs.count; i++) {
        NSData *value = serviceData[serviceDataUUIDs[i]];
        data[i] = value.bytes;
        lengths[i] = value.length;
    }
    advertisement.service_data = data;
    advertisement.service_data_lengths = lengths;
    advertisement.service_data_count = serviceDataUUIDs.count;

    DGEvents.discovered(DGEventsContext, &advertisement);
    free(strings);
    free(data);
    free(lengths);
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    DGComplete(DGKey(@"connect", peripheral.identifier.UUIDString), nil);
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    DGComplete(DGKey(@"connect", peripheral.identifier.UUIDString), error ?: DGError(DGErrorDisconnected));
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    NSString *identifier = peripheral.identifier.UUIDString;
    DGFailAll(identifier, DGError(DGErrorDisconnected));
    if (DGEvents.disconnected) DGEvents.disconnected(DGEventsContext, identifier.UTF8String, DGErrorCode(error));
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    DGComplete(DGKey(@"services", peripheral.identifier.UUIDString), error);
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(NSError *)error {
    DGComplete(DGKey(@"characteristics", @(DGHandle(service))), error);
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverDescriptorsForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    DGComplete(DGKey(@"descriptors", @(DGHandle(characteristic))), error);
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    unsigned long handle = DGHandle(characteristic);
    // A read takes the value; otherwise it is a notification.
    if (DGComplete(DGKey(@"read", @(handle)), error)) return;
    if (!error && characteristic.isNotifying && DGEvents.notified) {
        NSData *value = characteristic.value;
        DGEvents.notified(DGEventsContext, handle, value.bytes, value.length);
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    DGComplete(DGKey(@"write", @(DGHandle(characteristic))), error);
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    DGComplete(DGKey(@"notify", @(DGHandle(characteristic))), error);
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForDescriptor:(CBDescriptor *)descriptor
             error:(NSError *)error {
    DGComplete(DGKey(@"readDescriptor", @(DGHandle(descriptor))), error);
}

- (void)peripheral:(CBPeripheral *)peripheral
didWriteValueForDescriptor:(CBDescriptor *)descriptor
             error:(NSError *)error {
    DGComplete(DGKey(@"writeDescriptor", @(DGHandle(descriptor))), error);
}

- (void)peripheral:(CBPeripheral *)peripheral didReadRSSI:(NSNumber *)RSSI error:(NSError *)error {
    objc_setAssociatedObject(peripheral, @selector(readRSSI), RSSI, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    DGComplete(DGKey(@"rssi", peripheral.identifier.UUIDString), error);
}

@end

#pragma mark - Central

void dg_central_start(long showPowerAlert, const DGCentralEvents *events, void *context) {
    if (DGCentral) return;
    DGEvents = *events;
    DGEventsContext = context;
    DGPeripherals = [NSMutableDictionary dictionary];
    DGAttributes = [NSMutableArray array];
    DGHandles = [NSMapTable strongToStrongObjectsMapTable];
    DGPending = [NSMutableDictionary dictionary];
    DGPendingPeripheral = [NSMutableDictionary dictionary];
    DGCentralDelegate = [[DGDelegate alloc] init];
    DGCentral = [[CBCentralManager alloc] initWithDelegate:DGCentralDelegate
                                                     queue:dispatch_get_main_queue()
                                                   options:@{CBCentralManagerOptionShowPowerAlertKey: @(showPowerAlert != 0)}];
}

long dg_central_state(void) {
    return DGCentral.state;
}

void dg_central_scan(const char *const *services, long count, long allowDuplicates) {
    [DGCentral scanForPeripheralsWithServices:DGUUIDs(services, count)
                                      options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @(allowDuplicates != 0)}];
}

void dg_central_stop_scan(void) {
    [DGCentral stopScan];
}

unsigned long dg_time_milliseconds(void) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    return (unsigned long)(mach_absolute_time() * timebase.numer / timebase.denom / NSEC_PER_MSEC);
}

#pragma mark - Peripherals

static CBPeripheral *DGFindPeripheral(const char *identifier) {
    return DGPeripherals[DGString(identifier)];
}

void dg_connect(const char *identifier, DGCallback done, void *context) {
    CBPeripheral *peripheral = DGFindPeripheral(identifier);
    if (!peripheral) {
        done(context, DGErrorUnknownPeripheral);
        return;
    }
    if (peripheral.state == CBPeripheralStateConnected) {
        done(context, DGErrorNone);
        return;
    }
    DGEnqueue(peripheral, DGKey(@"connect", peripheral.identifier.UUIDString), ^(NSError *error) {
        done(context, DGErrorCode(error));
    });
    [DGCentral connectPeripheral:peripheral options:nil];
}

void dg_disconnect(const char *identifier) {
    CBPeripheral *peripheral = DGFindPeripheral(identifier);
    if (peripheral) [DGCentral cancelPeripheralConnection:peripheral];
}

long dg_is_connected(const char *identifier) {
    CBPeripheral *peripheral = DGFindPeripheral(identifier);
    if (!peripheral) return -1;
    return peripheral.state == CBPeripheralStateConnected ? 1 : 0;
}

long dg_maximum_write_length(const char *identifier) {
    CBPeripheral *peripheral = DGFindPeripheral(identifier);
    if (!peripheral || peripheral.state != CBPeripheralStateConnected) return -1;
    return [peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse];
}

void dg_read_rssi(const char *identifier, DGValueCallback done, void *context) {
    CBPeripheral *peripheral = DGFindPeripheral(identifier);
    if (!peripheral || peripheral.state != CBPeripheralStateConnected) {
        done(context, peripheral ? DGErrorDisconnected : DGErrorUnknownPeripheral, 0);
        return;
    }
    DGEnqueue(peripheral, DGKey(@"rssi", peripheral.identifier.UUIDString), ^(NSError *error) {
        NSNumber *rssi = objc_getAssociatedObject(peripheral, @selector(readRSSI));
        done(context, DGErrorCode(error), rssi.longValue);
    });
    [peripheral readRSSI];
}

#pragma mark - Discovery

void dg_discover_services(const char *identifier, const char *const *uuids, long count,
                          DGAttributesCallback done, void *context) {
    CBPeripheral *peripheral = DGFindPeripheral(identifier);
    if (!peripheral || peripheral.state != CBPeripheralStateConnected) {
        done(context, peripheral ? DGErrorDisconnected : DGErrorUnknownPeripheral, NULL, 0);
        return;
    }
    DGEnqueue(peripheral, DGKey(@"services", peripheral.identifier.UUIDString), ^(NSError *error) {
        DGReportAttributes(peripheral.services ?: @[], error, done, context);
    });
    [peripheral discoverServices:DGUUIDs(uuids, count)];
}

void dg_discover_characteristics(unsigned long handle, const char *const *uuids, long count,
                                 DGAttributesCallback done, void *context) {
    CBService *service = DGFindAttribute(handle, [CBService class]);
    if (!service) {
        done(context, DGErrorInvalidAttribute, NULL, 0);
        return;
    }
    if (service.peripheral.state != CBPeripheralStateConnected) {
        done(context, DGErrorDisconnected, NULL, 0);
        return;
    }
    DGEnqueue(service.peripheral, DGKey(@"characteristics", @(handle)), ^(NSError *error) {
        DGReportAttributes(service.characteristics ?: @[], error, done, context);
    });
    [service.peripheral discoverCharacteristics:DGUUIDs(uuids, count) forService:service];
}

void dg_discover_descriptors(unsigned long handle, DGAttributesCallback done, void *context) {
    CBCharacteristic *characteristic = DGFindAttribute(handle, [CBCharacteristic class]);
    if (!characteristic) {
        done(context, DGErrorInvalidAttribute, NULL, 0);
        return;
    }
    CBPeripheral *peripheral = DGPeripheralOf(characteristic);
    if (peripheral.state != CBPeripheralStateConnected) {
        done(context, DGErrorDisconnected, NULL, 0);
        return;
    }
    DGEnqueue(peripheral, DGKey(@"descriptors", @(handle)), ^(NSError *error) {
        DGReportAttributes(characteristic.descriptors ?: @[], error, done, context);
    });
    [peripheral discoverDescriptorsForCharacteristic:characteristic];
}

#pragma mark - Values

void dg_read_characteristic(unsigned long handle, DGDataCallback done, void *context) {
    CBCharacteristic *characteristic = DGFindAttribute(handle, [CBCharacteristic class]);
    if (!characteristic) {
        done(context, DGErrorInvalidAttribute, NULL, 0);
        return;
    }
    CBPeripheral *peripheral = DGPeripheralOf(characteristic);
    if (peripheral.state != CBPeripheralStateConnected) {
        done(context, DGErrorDisconnected, NULL, 0);
        return;
    }
    DGEnqueue(peripheral, DGKey(@"read", @(handle)), ^(NSError *error) {
        DGReportData(characteristic.value, error, done, context);
    });
    [peripheral readValueForCharacteristic:characteristic];
}

void dg_write_characteristic(unsigned long handle, const unsigned char *bytes, long length,
                             long withResponse, DGCallback done, void *context) {
    CBCharacteristic *characteristic = DGFindAttribute(handle, [CBCharacteristic class]);
    if (!characteristic) {
        done(context, DGErrorInvalidAttribute);
        return;
    }
    CBPeripheral *peripheral = DGPeripheralOf(characteristic);
    if (peripheral.state != CBPeripheralStateConnected) {
        done(context, DGErrorDisconnected);
        return;
    }
    NSData *data = [NSData dataWithBytes:bytes length:length];
    if (!withResponse) {
        [peripheral writeValue:data forCharacteristic:characteristic type:CBCharacteristicWriteWithoutResponse];
        done(context, peripheral.state == CBPeripheralStateConnected ? DGErrorNone : DGErrorDisconnected);
        return;
    }
    DGEnqueue(peripheral, DGKey(@"write", @(handle)), ^(NSError *error) {
        done(context, DGErrorCode(error));
    });
    [peripheral writeValue:data forCharacteristic:characteristic type:CBCharacteristicWriteWithResponse];
}

void dg_set_notify(unsigned long handle, long enabled, DGCallback done, void *context) {
    CBCharacteristic *characteristic = DGFindAttribute(handle, [CBCharacteristic class]);
    if (!characteristic) {
        done(context, DGErrorInvalidAttribute);
        return;
    }
    CBPeripheral *peripheral = DGPeripheralOf(characteristic);
    if (peripheral.state != CBPeripheralStateConnected) {
        done(context, DGErrorDisconnected);
        return;
    }
    DGEnqueue(peripheral, DGKey(@"notify", @(handle)), ^(NSError *error) {
        done(context, DGErrorCode(error));
    });
    [peripheral setNotifyValue:enabled != 0 forCharacteristic:characteristic];
}

void dg_read_descriptor(unsigned long handle, DGDataCallback done, void *context) {
    CBDescriptor *descriptor = DGFindAttribute(handle, [CBDescriptor class]);
    if (!descriptor) {
        done(context, DGErrorInvalidAttribute, NULL, 0);
        return;
    }
    CBPeripheral *peripheral = DGPeripheralOf(descriptor);
    if (peripheral.state != CBPeripheralStateConnected) {
        done(context, DGErrorDisconnected, NULL, 0);
        return;
    }
    DGEnqueue(peripheral, DGKey(@"readDescriptor", @(handle)), ^(NSError *error) {
        DGReportData(DGDescriptorData(descriptor.value), error, done, context);
    });
    [peripheral readValueForDescriptor:descriptor];
}

void dg_write_descriptor(unsigned long handle, const unsigned char *bytes, long length,
                         DGCallback done, void *context) {
    CBDescriptor *descriptor = DGFindAttribute(handle, [CBDescriptor class]);
    if (!descriptor) {
        done(context, DGErrorInvalidAttribute);
        return;
    }
    CBPeripheral *peripheral = DGPeripheralOf(descriptor);
    if (peripheral.state != CBPeripheralStateConnected) {
        done(context, DGErrorDisconnected);
        return;
    }
    DGEnqueue(peripheral, DGKey(@"writeDescriptor", @(handle)), ^(NSError *error) {
        done(context, DGErrorCode(error));
    });
    [peripheral writeValue:[NSData dataWithBytes:bytes length:length] forDescriptor:descriptor];
}
