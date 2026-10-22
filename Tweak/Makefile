# Theos optimisations

ARCHS = arm64 arm64e

ifeq ($(ROOTLESS),1)
	TARGET = iphone:clang:latest:15.0
endif

# Processes die if they are killed

INSTALL_TARGET_PROCESSES = SpringBoard

# Jinx is compiled straight into the dylib. The previous build found it in
# Xcode's DerivedData, which only exists on a Mac that has opened the package.

JINX_DIR = $(THEOS_PROJECT_DIR)/vendor/Jinx
JINX_SOURCES = $(shell find $(JINX_DIR)/Sources/Jinx -name '*.swift' 2>/dev/null)

# Define included files, imported frameworks, etc.
#
# There are deliberately no private frameworks here: SpringBoard classes are
# reached through the ObjC runtime (Helpers/SpringBoard.swift) and the IOPM
# symbols through dlopen, so the build needs no private headers or stubs.

LIBRARY_NAME = Reverie
$(LIBRARY_NAME)_FILES = Sources/load.s $(shell find Sources/$(LIBRARY_NAME) -name '*.swift') $(JINX_SOURCES)

# library.mk defaults the install path to /usr/lib, which is also why the old
# build could not find the dylib it was supposed to re-sign. Keep the dylib with
# the other tweak dylibs.
$(LIBRARY_NAME)_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

ifeq ($(ROOTLESS),1)
$(LIBRARY_NAME)_CFLAGS += -DJINX_ROOTLESS
$(LIBRARY_NAME)_SWIFTFLAGS = -DJINX_ROOTLESS
endif

# Theos makefiles to include

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
include $(THEOS_MAKE_PATH)/library.mk

# Rootless support? with a question mark

DYLIB_DIR = $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries

# library.mk only knows about the dylib, unlike tweak.mk which also copies the
# MobileLoader filter next to it, so install the filter ourselves.
internal-stage::
	@$(PRINT_FORMAT_MAKING) "Installing $(LIBRARY_NAME) filter"

	$(ECHO_NOTHING)cp "$(LIBRARY_NAME).plist" "$(DYLIB_DIR)/$(LIBRARY_NAME).plist"$(ECHO_END)

ifeq ($(ROOTLESS),1)
internal-stage::
	@$(PRINT_FORMAT_MAKING) "Re-signing $(LIBRARY_NAME)"

	$(ECHO_NOTHING)ldid -S "$(DYLIB_DIR)/$(LIBRARY_NAME).dylib"$(ECHO_END)
endif
