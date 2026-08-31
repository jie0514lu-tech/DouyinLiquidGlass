# 设置面板 bundle（preferenceloader）
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DouyinLiquidGlassPrefs

DouyinLiquidGlassPrefs_FILES =
DouyinLiquidGlassPrefs_INSTALL_PATH = /Library/PreferenceBundles
DouyinLiquidGlassPrefs_FRAMEWORKS = UIKit
DouyinLiquidGlassPrefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS)/makefiles/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/DouyinLiquidGlassPrefs.plist$(ECHO_END)
