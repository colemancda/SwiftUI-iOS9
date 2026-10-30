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
| Modifiers | `font`, `foregroundColor`, `foregroundStyle(Color)`, `padding`, `frame(width:height:)`, `frame(maxWidth:maxHeight:)`, `background(Color)`, `onAppear`, `onDisappear` |
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
  `@EnvironmentObject` looks its object up by type in the render context the
  first time it's read during a render.
- **Lists:** a `UIScrollView` of rows, keyed by position so the scroll offset
  survives re-renders. `ForEach` over `Identifiable` data keys each row by `id`,
  so state and pushed screens follow an element when the data reorders.
- **The C boundary:** Swift is compiled for bare-metal armv7, whose calling
  convention differs from iOS's for floating-point and struct arguments. The
  backend API therefore only passes pointers and integers: sizes in whole points,
  colors as `0xRRGGBBAA`.

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
make                                                   # build Examples/Counter
make install                                           # copy to the device
make EXAMPLE=Devices install                           # build Examples/Devices
```

`Examples/Devices` is a list of devices that drills down into details, using
`NavigationView`, `List`, `NavigationLink` and an `@EnvironmentObject` store.

`make install` needs a jailbroken device with OpenSSH and a USB tunnel
(`iproxy 2222:22` from libimobiledevice). It uses an SSH config file (`SSH_CONF`)
with a host entry for the device (`SSH_HOST`, default `4s`). The app goes into
`/Applications`, where a jailbroken device runs it without AppSync.

### Toolchain fixes

- **ARM mode, not Thumb** (`-marm`, `-Xcc -marm`): Xcode's linker writes an even
  entry offset for a Thumb `main()`, so it starts in ARM state and crashes.
- **`-Xcc -ffixed-r9`:** iOS lets functions overwrite `r9`, but the bare-metal
  armv7 target expects it preserved across calls.
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
- `@EnvironmentObject` must be read during a render (in `body`) before an
  action uses it.
- Layout is UIKit Auto Layout through `UIStackView`, so results are close to
  SwiftUI's, not identical.
