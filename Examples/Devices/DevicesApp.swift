import SwiftUI

// A list of nearby devices that drills down into details, shaped like a
// Bluetooth scanner app. Each tap of the scan button simulates an
// advertisement: a new device, or a new reading from a known one.

@main
struct DevicesApp: App {
    let store = DeviceStore()

    var body: some Scene {
        WindowGroup {
            NavigationView {
                DeviceList()
            }
            .environmentObject(store)
        }
    }
}

struct Device: Identifiable {
    let id: Int
    let model: String
    let name: String
    var temperature: Int
    var humidity: Int
    var battery: Int
}

final class DeviceStore: ObservableObject {
    @Published var devices: [Device] = []

    private var found = 0

    /// "Discovers" a device, or refreshes a reading once all are found.
    func scan() {
        if found < 5 {
            let models = ["H5075", "H5179", "H7130", "H7173", "H7126"]
            devices.append(Device(
                id: found,
                model: models[found],
                name: "GV\(models[found])_\(1000 + found * 1111)",
                temperature: 200 + found * 7,
                humidity: 400 + found * 31,
                battery: 100 - found * 9
            ))
            found += 1
        } else {
            let index = Int(found % devices.count)
            devices[index].temperature += found % 2 == 0 ? 1 : -1
            found += 1
        }
    }
}

struct DeviceList: View {
    @EnvironmentObject var store: DeviceStore

    var body: some View {
        List {
            ForEach(store.devices) { device in
                NavigationLink(destination: DeviceDetail(device: device)) {
                    DeviceRow(device: device)
                }
            }
        }
        .navigationTitle("Devices")
        .navigationBarItems(trailing: scanButton)
        .onAppear {
            if store.devices.isEmpty { store.scan() }
        }
    }

    var scanButton: some View {
        Button(action: { store.scan() }) {
            Image(systemName: "arrow.clockwise")
                .font(.title2)
        }
    }
}

struct DeviceRow: View {
    let device: Device

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "thermometer")
                Text(verbatim: device.model)
                    .font(.title3)
            }
            Text(verbatim: device.name)
                .foregroundColor(.gray)
                .font(.subheadline)
            Text("Temperature: \(tenths(device.temperature))°C")
                .font(.subheadline)
        }
    }
}

struct DeviceDetail: View {
    let device: Device

    var body: some View {
        List {
            Text("Name: \(device.name)")
            Text("Temperature: \(tenths(device.temperature))°C")
            Text("Humidity: \(tenths(device.humidity))%")
            Text("Battery: \(device.battery)%")
        }
        .navigationTitle(device.model)
    }
}

/// Formats a value in tenths, such as 215 as "21.5".
func tenths(_ value: Int) -> String {
    "\(value / 10).\(abs(value % 10))"
}
