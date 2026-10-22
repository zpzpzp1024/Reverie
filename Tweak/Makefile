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

ifeq ($(ROOTLESS),1)
$(LIBRARY_NAME)_SWIFTFLAGS = -DJINX_ROOTLESS
endif

# Theos makefiles to include

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
include $(THEOS_MAKE_PATH)/library.mk

# Rootless support? with a question mark

ifeq ($(ROOTLESS),1)
$(LIBRARY_NAME)_CFLAGS += -DJINX_ROOTLESS
DYLIB_PATH = $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/$(LIBRARY_NAME).dylib

internal-stage::
	@$(PRINT_FORMAT_MAKING) "Re-signing $(LIBRARY_NAME)"
	
	$(ECHO_NOTHING)ldid -S "$(DYLIB_PATH)"$(ECHO_END)
endif
