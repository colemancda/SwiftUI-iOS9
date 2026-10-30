# Builds SwiftUI apps for iOS 9 / armv7 (iPhone 4S) with Embedded Swift.
#
#   make                       build the example in EXAMPLE (default Counter)
#   make install               copy it to a jailbroken device over SSH
#   make EXAMPLE=Other install
#
# Needs Xcode (clang, ld), a swift.org toolchain (Embedded stdlib) and the
# iOS 9.3 SDK in ./sdk (`make sdk`).

EXAMPLE  ?= Counter
APP      := $(EXAMPLE)
BUNDLE   := build/$(APP).app
SDK      := sdk/iPhoneOS9.3.sdk
MIN_IOS  := 9.0
ARCH     := armv7

# Preserved, unmodified iPhoneOS9.3.sdk.tar.xz from github.com/theos/sdks
SDK_ARCHIVE ?= /Volumes/4TB/Downloads/iPhoneOS9.3.sdk.tar.xz

SWIFT_TOOLCHAIN ?= $(HOME)/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain
SWIFTC := $(SWIFT_TOOLCHAIN)/usr/bin/swiftc
SWIFT_EMBEDDED_LIB := $(SWIFT_TOOLCHAIN)/usr/lib/swift/embedded/armv7-apple-none-macho
CC     := xcrun clang

# Xcode's linker writes an even LC_MAIN entry offset for Thumb code, so a
# Thumb main() is entered in ARM state and crashes: build everything as ARM.
CFLAGS  := -arch $(ARCH) -isysroot $(SDK) -miphoneos-version-min=$(MIN_IOS) \
           -marm -fobjc-arc -O2 -Wall -ISources/CSwiftUIBackend/include
# String comparison and normalization need the stdlib's Unicode tables;
# only the parts an app uses are linked.
LDFLAGS := -arch $(ARCH) -isysroot $(SDK) -miphoneos-version-min=$(MIN_IOS) \
           -framework UIKit -framework Foundation \
           $(SWIFT_EMBEDDED_LIB)/libswiftUnicodeDataTables.a

# There's no Embedded stdlib for armv7-apple-ios, so Swift targets bare-metal
# armv7 Mach-O and is linked into the iOS binary. -ffixed-r9: iOS lets callees
# clobber r9, but the bare-metal convention expects it preserved.
SWIFTFLAGS := -target armv7-apple-none-macho -enable-experimental-feature Embedded \
              -wmo -Osize -Xcc -marm -Xcc -ffixed-r9 \
              -ISources/CSwiftUIBackend/include -Ibuild/modules

SWIFTUI_SRCS := $(wildcard Sources/SwiftUI/*.swift)
APP_SRCS     := $(wildcard Examples/$(EXAMPLE)/*.swift)

SSH_CONF ?= /Volumes/4TB/Downloads/IPA/4s-ssh.conf
SSH_HOST ?= 4s

.PHONY: all install sdk clean
.DEFAULT_GOAL := all

all: $(BUNDLE)/$(APP)

# Also writes build/modules/SwiftUI.swiftmodule.
build/obj/SwiftUI.o: $(SWIFTUI_SRCS) Sources/CSwiftUIBackend/include/SwiftUIBackend.h
	@mkdir -p build/modules build/obj
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-name SwiftUI \
	  -emit-module -emit-module-path build/modules/SwiftUI.swiftmodule \
	  -c $(SWIFTUI_SRCS) -o $@

build/obj/$(APP).o: $(APP_SRCS) build/obj/SwiftUI.o
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -module-name $(APP) -c $(APP_SRCS) -o $@

build/obj/Backend.o: Sources/CSwiftUIBackend/Backend.m Sources/CSwiftUIBackend/include/SwiftUIBackend.h
	@mkdir -p build/obj
	$(CC) $(CFLAGS) -c $< -o $@

# The linker warns "no platform load command found" for the Swift objects
# (bare-metal target) and assumes iOS, which is what we want.
$(BUNDLE)/$(APP): build/obj/$(APP).o build/obj/SwiftUI.o build/obj/Backend.o Examples/$(EXAMPLE)/Info.plist
	@mkdir -p $(BUNDLE)
	$(CC) $(LDFLAGS) build/obj/$(APP).o build/obj/SwiftUI.o build/obj/Backend.o -o $@.tmp
	ldid -S $@.tmp
	mv $@.tmp $@
	plutil -convert binary1 -o $(BUNDLE)/Info.plist Examples/$(EXAMPLE)/Info.plist
	printf 'APPL????' > $(BUNDLE)/PkgInfo

# Copies the app into /Applications (runs without AppSync on a jailbroken
# device) and refreshes the home screen.
install: $(BUNDLE)/$(APP)
	COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C build -cf - $(APP).app | \
	  ssh -F $(SSH_CONF) $(SSH_HOST) 'cd / && rm -rf /Applications/$(APP).app && tar -C /Applications -xf - && chown -R root:wheel /Applications/$(APP).app && su mobile -c uicache'

# Unpacks the SDK and fixes its .tbd stubs for Xcode's linker: drops the
# simulator architectures (otherwise read as simulator-only) and adds the
# mem* functions Swift's stdlib calls but the stubs leave out.
sdk:
	rm -rf $(SDK) && mkdir -p sdk
	tar -xJf $(SDK_ARCHIVE) -C sdk
	find $(SDK) -name '*.tbd' -type f -print0 | xargs -0 sed -i '' -E \
	  's/(archs: *\[ armv7, armv7s, arm64), i386, x86_64 \]/\1 ]/'
	perl -0pi -e 's/(symbols: *\[ )/$$1_bzero, _memcmp, _memcpy, _memmove, _memset, /' \
	  $(SDK)/usr/lib/system/libsystem_platform.tbd

clean:
	rm -rf build
