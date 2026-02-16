export LOGOS_DEFAULT_GENERATOR = internal

# Dynamically swap architecture and target based on build environment
ifeq ($(MODERN_ARM64E),1)
  TARGET := iphone:clang:latest:16.0
  ARCHS = arm64e
else
  TARGET := iphone:clang:latest:11.0
  ARCHS = arm64
endif

INSTALL_TARGET_PROCESSES = RedditApp Reddit

PACKAGE_VERSION = 1.2.0
ifdef APP_VERSION
  PACKAGE_VERSION := $(APP_VERSION)-$(PACKAGE_VERSION)
endif

ifeq ($(SIDELOADED),1)
  export MODULES = jailed
  CODESIGN_IPA = 0
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RedditFilter

$(TWEAK_NAME)_FILES = $(wildcard *.x*) $(wildcard *.m)
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Iinclude -Wno-module-import-in-extern-c -O2

ifeq ($(SIDELOADED),1)
  $(TWEAK_NAME)_INJECT_DYLIBS = $(THEOS_OBJ_DIR)/RedditSideloadFix.dylib
  SUBPROJECTS += RedditSideloadFix
  include $(THEOS_MAKE_PATH)/aggregate.mk
endif

include $(THEOS_MAKE_PATH)/tweak.mk
