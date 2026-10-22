# Basic environment configuration

export SYSROOT = $(THEOS)/sdks/$(or $(THEOS_SDK),iPhoneOS16.5.sdk)/
export TARGET = iphone:clang:latest:13.0
export ROOTLESS = 1

# Theos optimisations

export FINALPACKAGE = 1
export DEBUG = 0
export THEOS_LEAN_AND_MEAN = 1
export USING_JINX = 1

# Vendored Swift dependencies
#
# These used to be resolved through Xcode's DerivedData, which only exists on a
# machine that has opened the SwiftPM package in Xcode. They are plain clones now
# so the same tree builds on a Mac, in CI and in a container.

JINX_VERSION ?= development
JINXPREFS_VERSION ?= emt

# Define subprojects

SUBPROJECTS += CC Prefs Tweak

# Theos makefiles to include

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

# Fetch build dependencies

.PHONY: setup
setup::
	@test -d vendor/Jinx/Sources/Jinx || git clone --depth 1 -b $(JINX_VERSION) https://github.com/Paisseon/Jinx.git vendor/Jinx
	@test -d vendor/JinxPrefs/Sources/JinxPrefs || git clone --depth 1 -b $(JINXPREFS_VERSION) https://github.com/Paisseon/JinxPrefs.git vendor/JinxPrefs
	@echo "dependencies ready"

# Rootless support? with a question mark

ifeq ($(ROOTLESS),1)
internal-stage::
	@$(PRINT_FORMAT_MAKING) "Moving files to rootless paths"
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/var/jb/Library"$(ECHO_END)
	$(ECHO_NOTHING)mv "$(THEOS_STAGING_DIR)/Library" "$(THEOS_STAGING_DIR)/var/jb"$(ECHO_END)

before-package::
	@$(PRINT_FORMAT_MAKING) "Patching control file architecture"
	$(ECHO_NOTHING)perl -pi -e 's/iphoneos-arm/iphoneos-arm64/' "$(THEOS_STAGING_DIR)/DEBIAN/control"$(ECHO_END)
endif
