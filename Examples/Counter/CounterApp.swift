import SwiftUI

@main
struct CounterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var count = 0

    var body: some View {
        VStack(spacing: 20) {
            Text("SwiftUI on iOS 9")
                .font(.title)

            Text("Count: \(count)")
                .font(.largeTitle.bold())
                .foregroundColor(count < 0 ? .red : .primary)

            HStack(spacing: 32) {
                Button("−") { count -= 1 }
                Button("+") { count += 1 }
            }
            .font(.system(size: 44))

            if count >= 10 {
                Text("Double digits!")
                    .foregroundColor(.green)
            }

            Button(action: { count = 0 }) {
                Text("Reset")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(.blue)
            }
            .foregroundColor(.white)
        }
        .padding()
    }
}
