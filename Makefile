export LOGOS_DEFAULT_GENERATOR = internal

TARGET := iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = RedditApp Reddit

ARCHS = arm64

PACKAGE_VERSION = 1.2.6
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
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Iinclude -Wno-module-import-in-extern-c

# Debug menu: off unless you build with DEBUG_MENU=1 (the GitHub build has a checkbox for it)
ifeq ($(DEBUG_MENU),1)
  $(TWEAK_NAME)_CFLAGS += -DREDDITFILTER_DEBUG=1
endif
$(TWEAK_NAME)_INJECT_DYLIBS = $(THEOS_OBJ_DIR)/RedditSideloadFix.dylib

ifeq ($(SIDELOADED),1)
  SUBPROJECTS += RedditSideloadFix
  include $(THEOS_MAKE_PATH)/aggregate.mk
endif

include $(THEOS_MAKE_PATH)/tweak.mk

