# SwiftUI-iOS9

A SwiftUI-compatible UI library in Embedded Swift for iOS 9 on 32-bit devices
(iPhone 4S, armv7), for porting simple SwiftUI apps to hardware that SwiftUI
never supported.

The module is named `SwiftUI`, so app code keeps `import SwiftUI`:

```swift
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
            Text("Count: \(count)")
                .font(.largeTitle.bold())
            HStack(spacing: 32) {
                Button("−") { count -= 1 }
                Button("+") { count += 1 }
            }
        }
        .padding()
    }
}
```

## What's supported

| | |
|---|---|
| App | `App`, `@main`, `Scene`, `WindowGroup` |
| Views | `Text`, `Button` (title or custom label), `VStack`, `HStack`, `Spacer`, `ForEach` (ranges, `Identifiable` data), `Color`, `EmptyView`, `AnyView`, `Image(systemName:)` |
| Navigation | `NavigationView`, `NavigationLink(destination:label:)`, `navigationTitle`, `navigationBarItems(trailing:)` |
| Lists | `List` (plain style, `NavigationLink` rows get a chevron) |
| Builders | `@ViewBuilder` with any number of children, `if`, `if`/`else` |
| State | `@State`, `Binding`, `$value`, `ObservableObject`, `@Published`, `@ObservedObject`, `@StateObject`, `@EnvironmentObject`, `environmentObject(_:)` |
| Modifiers | `font`, `foregroundColor`, `foregroundStyle(Color)`, `padding`, `frame(width:height:)`, `frame(maxWidth:maxHeight:)`, `background(Color)`, `onAppear`, `onDisappear`, `task` |
| Concurrency | `async`/`await`, `Task`, actors, `Task.sleep(nanoseconds:)`, cancellation |
| Values | `Font` text styles, `.system(size:weight:)`, `.bold()`; system `Color`s, `Color(red:green:blue:)`; `CGFloat`, `Edge.Set` |

## How it works

```
App code (Embedded Swift)
  └─ SwiftUI module (Embedded Swift)        Sources/SwiftUI
       └─ C API                              Sources/CSwiftUIBackend/include/SwiftUIBackend.h
            └─ UIKit backend (Objective-C)   Sources/CSwiftUIBackend/Backend.m
```

- **Rendering:** each view renders itself into UIKit views: `UILabel`, `UIButton`,
  `UIStackView` for stacks, and plain views for padding and backgrounds. Any
  `@State` change schedules a re-render on the next run-loop turn, which
  rebuilds the whole view tree. That's simple and fast enough for small screens.
- **State:** Embedded Swift has no reflection, so `@State` can't be found by
  inspecting a view. Each `body` evaluation instead runs in a scope keyed by the
  view's position in the tree, and every `State` created in it takes the next
  slot. State whose view disappears is dropped after the render.
- **Navigation:** a `NavigationView` is a `UINavigationController` kept across
  renders. Its stack is the list of links pushed so far: each render draws the
  root, then the destination of the link pushed from it, and so on, so pushed
  screens stay live. A level whose link disappears is popped.
- **Observable objects:** there's no Combine. Since every update re-renders
  everything, setting a `@Published` property just schedules a render.
  `@EnvironmentObject` looks its object up by type in the render context when
  the view is created, or else the first time it's read during a render.
- **Concurrency:** all tasks run on the main queue. `Executor.c` replaces
  Embedded Swift's default executor, whose loop would block UIKit, and is
  compiled for the bare-metal target because the runtime calls it with the
  Swift calling convention. Embedded Swift has no clocks, so `Task.sleep` is
  provided here using a main-queue timer, and `import SwiftUI` re-exports the
  concurrency module.
- **Lists:** a `UIScrollView` of rows, keyed by position so the scroll offset
  survives re-renders. `ForEach` over `Identifiable` data keys each row by `id`,
  so state and pushed screens follow an element when the data reorders.
- **The C boundary:** Swift is compiled for bare-metal armv7, whose calling
  convention differs from iOS's for floating-point and struct arguments. The
  backend API therefore only passes pointers and integers: sizes in whole points,
  colors as `0xRRGGBBAA`.

## Bluetooth (DarwinGATT)

`Sources/DarwinGATT` is a Bluetooth LE central for iOS 9, implementing
[GATT](https://github.com/PureSwift/GATT)'s `CentralManager` on top of
CoreBluetooth, with the same API as GATT's `DarwinCentral` (`state`,
`scan(with:filterDuplicates:)`, `connect`, `notify`, …). Its Objective-C half
(`Sources/CDarwinGATT`) runs one `CBCentralManager` on the main queue, where
Swift tasks also run, and passes only pointers and integers to Swift.

It depends on the [Bluetooth](https://github.com/PureSwift/Bluetooth) (8.2.0
or later) and GATT (4.1.0 or later) modules, compiled for Embedded Swift by the
app's build; this repo's Makefile doesn't build it. The
[Govee](https://github.com/MillerTechnologyPeru/Govee) iOS 9 port
(`iOS9/Makefile`) is an example.

Apps using it must be **signed with a team identifier**, for example with an
Apple Development identity and `codesign`, not ad-hoc with `ldid`. iOS 9's
Bluetooth daemon only treats an app as being in the foreground if its
signature has one; otherwise the app only gets results from scans filtered by
service UUID.

## Building

Requirements:

- Xcode (tested with 27.1) for `clang`, the linker and `plutil`.
- The [swift.org](https://www.swift.org/install/macos/) toolchain (tested with
  6.4.2), because Xcode's Swift has no Embedded standard library. Set
  `SWIFT_TOOLCHAIN` if it isn't at the default path.
- The iOS 9.3 SDK from [theos/sdks](https://github.com/theos/sdks)
  (`iPhoneOS9.3.sdk.tar.xz`, not checked in).
- [`ldid`](https://formulae.brew.sh/formula/ldid) for signing.

```bash
make sdk SDK_ARCHIVE=/path/to/iPhoneOS9.3.sdk.tar.xz   # once
make runtime                                           # once; also run by make
make                                                   # build Examples/Counter
make install                                           # copy to the device
make EXAMPLE=Devices install                           # build Examples/Devices
```

`Examples/Devices` is a list of devices that drills down into details, using
`NavigationView`, `List`, `NavigationLink` and an `@EnvironmentObject` store,
with a `.task` that simulates an advertisement every second.

`make runtime` rebuilds the concurrency runtime (see below) into
`build/runtime`. It downloads the runtime's sources for the toolchain's release
tag the first time, so it needs network access. `make clean` keeps it;
`make distclean` removes it.

`make install` needs a jailbroken device with OpenSSH and a USB tunnel
(`iproxy 2222:22` from libimobiledevice). It uses an SSH config file (`SSH_CONF`)
with a host entry for the device (`SSH_HOST`, default `4s`). The app goes into
`/Applications`, where a jailbroken device runs it without AppSync.

### Toolchain fixes

- **ARM mode, not Thumb** (`-marm`, `-Xcc -marm`): Xcode's linker doesn't set
  the Thumb bit in addresses of Thumb functions, neither the entry offset of
  `main()` nor function pointers, so calls through them run Thumb code in ARM
  state and crash.
- **`-Xcc -ffixed-r9`:** iOS lets functions overwrite `r9`, but the bare-metal
  armv7 target expects it preserved across calls.
- **Rebuilt concurrency runtime** (`Scripts/build-concurrency-runtime.sh`): the
  toolchain's `libswift_Concurrency.a` is Thumb code that keeps values in `r9`,
  so it crashes on iOS for both reasons above. The script compiles its C++
  sources with the official build's flags plus `-ffixed-r9` and `-marm`, and
  fails if any `r9` use or Thumb code remains. Without those two flags, the same
  flags reproduce the shipped objects, apart from C++ standard library
  templates from the local SDK.
- **SDK stubs** (`make sdk`): removes `i386, x86_64` from the `.tbd` files, which
  Xcode's linker otherwise reads as simulator-only, and adds `memcpy`, `memmove`,
  `memset`, `bzero` and `memcmp`, which the stubs leave out.
- The linker warns "no platform load command found" for the Swift objects and
  assumes iOS. That's expected.

## Limits

- Embedded Swift: no Foundation, `@objc`, reflection, `Codable`, key paths, or
  most `any` existentials. `ForEach(_:id:)` with a key path isn't available; use
  ranges or `Identifiable` data.
- State is matched by position. A view that moves (for example, into a
  different `if` branch) starts with fresh state.
- No `TextField`, `Toggle`, `Section`, `NavigationStack`, list styles,
  animations or gestures yet.
- iOS 9 has no SF Symbols: `Image(systemName:)` draws a similar Unicode
  character for common symbol names, and nothing for the rest.
- `Task.sleep` doesn't wake early when its task is cancelled; it throws
  `CancellationError` when the time is up. There are no clocks or
  `Task.sleep(for:)`.
- All tasks share the main thread: long synchronous work in a task blocks the UI.
- Layout is UIKit Auto Layout through `UIStackView`, so results are close to
  SwiftUI's, not identical.
