# Theos optimisations

ARCHS = arm64 arm64e

ifeq ($(ROOTLESS),1)
	TARGET = iphone:clang:latest:15.0
endif

# JinxPrefs is compiled straight into the bundle; SPM/DerivedData is not used.

JINXPREFS_DIR = $(THEOS_PROJECT_DIR)/vendor/JinxPrefs
JINXPREFS_SOURCES = $(shell find $(JINXPREFS_DIR)/Sources/JinxPrefs -name '*.swift' 2>/dev/null)

# Define included files, imported frameworks, etc.

BUNDLE_NAME = ReveriePrefs
$(BUNDLE_NAME)_FILES = $(shell find Sources/$(BUNDLE_NAME) -name '*.swift') $(JINXPREFS_SOURCES)
$(BUNDLE_NAME)_CFLAGS = -fobjc-arc
$(BUNDLE_NAME)_INSTALL_PATH = /Library/PreferenceBundles
$(BUNDLE_NAME)_PRIVATE_FRAMEWORKS = Preferences

ifeq ($(ROOTLESS),1)
$(BUNDLE_NAME)_SWIFTFLAGS = -DJINX_ROOTLESS
endif

# Theos makefiles to include

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
include $(THEOS_MAKE_PATH)/bundle.mk

# Rootless support? with a question mark

ifeq ($(ROOTLESS),1)
internal-stage::
	@$(PRINT_FORMAT_MAKING) "Re-signing $(BUNDLE_NAME)"
	
	$(ECHO_NOTHING)ldid -S "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/$(BUNDLE_NAME).bundle/$(BUNDLE_NAME)"$(ECHO_END)
	
	@$(PRINT_FORMAT_MAKING) "Copying preferences to PreferenceLoader"
	
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	
	$(ECHO_NOTHING)cp Resources/entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/$(BUNDLE_NAME).plist"$(ECHO_END)
else
internal-stage::
	@$(PRINT_FORMAT_MAKING) "Copying preferences to PreferenceLoader"
	
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	
	$(ECHO_NOTHING)cp Resources/entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/$(BUNDLE_NAME).plist"$(ECHO_END)
endif
