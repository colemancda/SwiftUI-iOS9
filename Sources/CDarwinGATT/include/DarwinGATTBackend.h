// C interface between the Embedded Swift `DarwinGATT` module and CoreBluetooth.
//
// Swift is compiled for bare-metal armv7, whose calling convention differs
// from iOS's for floating-point, 64-bit and struct arguments, so only
// pointers, `long` and `unsigned long` cross this boundary, and structs are
// passed by pointer with only those field types.
//
// There is one central manager, on the main queue, which is also where Swift
// tasks run. Peripherals are identified by their UUID string; services,
// characteristics and descriptors by handles that stay valid until the app
// exits. Completion callbacks are called once, on the main queue.

#ifndef DARWIN_GATT_BACKEND_H
#define DARWIN_GATT_BACKEND_H

/// Error codes passed to callbacks. 0 is success.
enum {
    DGErrorNone = 0,
    /// The peripheral is unknown, for example not seen in a scan.
    DGErrorUnknownPeripheral = 1,
    /// The handle doesn't name an attribute of the expected kind.
    DGErrorInvalidAttribute = 2,
    /// The peripheral isn't connected, or disconnected during the operation.
    DGErrorDisconnected = 3,
    /// An ATT error from the peripheral; the low byte is the ATT error code.
    DGErrorATT = 0x100,
    /// A CoreBluetooth error; the low byte is the `CBError` code.
    DGErrorCoreBluetooth = 0x200,
    /// Any other error.
    DGErrorOther = 0x300,
};

typedef struct {
    /// The peripheral's identifier, a UUID string.
    const char *peripheral;
    /// The local name, or null.
    const char *name;
    long rssi;
    /// -1 if unknown.
    long is_connectable;
    /// Manufacturer data including the company identifier, or null.
    const unsigned char *manufacturer_data;
    long manufacturer_data_length;
    long has_tx_power_level;
    long tx_power_level;
    /// UUID strings.
    const char *const *service_uuids;
    long service_uuid_count;
    const char *const *overflow_service_uuids;
    long overflow_service_uuid_count;
    const char *const *solicited_service_uuids;
    long solicited_service_uuid_count;
    /// Parallel arrays of service data.
    const char *const *service_data_uuids;
    const unsigned char *const *service_data;
    const long *service_data_lengths;
    long service_data_count;
} DGAdvertisement;

typedef struct {
    unsigned long handle;
    /// UUID string.
    const char *uuid;
    /// `CBCharacteristicProperties` for a characteristic; for a service,
    /// 1 if it is primary.
    long flags;
} DGAttribute;

typedef void (*DGCallback)(void *context, long error);
typedef void (*DGValueCallback)(void *context, long error, long value);
typedef void (*DGDataCallback)(void *context, long error, const unsigned char *bytes, long length);
typedef void (*DGAttributesCallback)(void *context, long error, const DGAttribute *attributes, long count);

/// Events from the central, all called with the context given to `dg_central_start`.
typedef struct {
    /// The central's state changed; see `dg_central_state`.
    void (*state_changed)(void *context, long state);
    /// A peripheral was found while scanning.
    void (*discovered)(void *context, const DGAdvertisement *advertisement);
    /// A connected peripheral disconnected.
    void (*disconnected)(void *context, const char *peripheral, long error);
    /// A characteristic with notifications on changed its value.
    void (*notified)(void *context, unsigned long characteristic, const unsigned char *bytes, long length);
} DGCentralEvents;

/// Creates the central manager. Call once.
void dg_central_start(long show_power_alert, const DGCentralEvents *events, void *context);

/// The `CBCentralManagerState`: 0 unknown, 1 resetting, 2 unsupported,
/// 3 unauthorized, 4 powered off, 5 powered on.
long dg_central_state(void);

/// Starts scanning for peripherals advertising any of the services (UUID
/// strings), or all peripherals if `count` is 0.
void dg_central_scan(const char *const *services, long count, long allow_duplicates);
void dg_central_stop_scan(void);

/// Monotonic time in milliseconds, for scan timestamps.
unsigned long dg_time_milliseconds(void);

void dg_connect(const char *peripheral, DGCallback done, void *context);
/// Cancels a connection; pending operations fail with `DGErrorDisconnected`.
void dg_disconnect(const char *peripheral);
/// 1 if connected, 0 if not, -1 if the peripheral is unknown.
long dg_is_connected(const char *peripheral);

void dg_discover_services(const char *peripheral, const char *const *uuids, long count,
                          DGAttributesCallback done, void *context);
void dg_discover_characteristics(unsigned long service, const char *const *uuids, long count,
                                 DGAttributesCallback done, void *context);
void dg_discover_descriptors(unsigned long characteristic, DGAttributesCallback done, void *context);

void dg_read_characteristic(unsigned long characteristic, DGDataCallback done, void *context);
/// Without response, `done` is called once the value is queued.
void dg_write_characteristic(unsigned long characteristic, const unsigned char *bytes, long length,
                             long with_response, DGCallback done, void *context);
void dg_set_notify(unsigned long characteristic, long enabled, DGCallback done, void *context);

void dg_read_descriptor(unsigned long descriptor, DGDataCallback done, void *context);
void dg_write_descriptor(unsigned long descriptor, const unsigned char *bytes, long length,
                         DGCallback done, void *context);

/// The largest value that can be written without response, or -1 if unknown.
long dg_maximum_write_length(const char *peripheral);
void dg_read_rssi(const char *peripheral, DGValueCallback done, void *context);

#endif
