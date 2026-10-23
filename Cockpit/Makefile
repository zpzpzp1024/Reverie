export SYSROOT = $(THEOS)/sdks/$(or $(THEOS_SDK),iPhoneOS16.5.sdk)/
export TARGET = iphone:clang:latest:15.0
export FINALPACKAGE = 1
export DEBUG = 0
export THEOS_LEAN_AND_MEAN = 1
export THEOS_PLATFORM_DEB_COMPRESSION_TYPE = xz

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Cockpit
Cockpit_FILES = Sources/Cockpit.mm
Cockpit_FRAMEWORKS = UIKit Foundation QuartzCore
Cockpit_CFLAGS = -fobjc-arc

# Rootless install location, same as the other tweaks on this device.
Cockpit_INSTALL_PATH = /var/jb/Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

internal-stage::
	@echo "Cockpit staged at $(THEOS_STAGING_DIR)"
