THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SingularityIsland

SingularityIsland_FILES = Tweak.x SingularityView.m
SingularityIsland_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -DSINGULARITY_ROOTLESS_PREFIX=\"/var/jb\"
SingularityIsland_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore AudioToolbox AVFoundation
SingularityIsland_PRIVATE_FRAMEWORKS = MediaRemote SpringBoardServices
SingularityIsland_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += Prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

# Ensure Tweak.plist is staged as the rootless filter plist under /var/jb
internal-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/var/jb/Library/MobileSubstrate/DynamicLibraries"$(ECHO_END)
	$(ECHO_NOTHING)cp -f "$(CURDIR)/Tweak.plist" "$(THEOS_STAGING_DIR)/var/jb/Library/MobileSubstrate/DynamicLibraries/$(TWEAK_NAME).plist"$(ECHO_END)
