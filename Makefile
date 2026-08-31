# DouyinLiquidGlass - 抖音 App 内液态玻璃插件
# 构建（需要 macOS + Theos，或 Linux + Theos 交叉编译）：
#   make clean && make package
# 打包成 rootless（Dopamine/palera1n 等新越狱）：
#   make clean && make package THEOS_PACKAGE_SCHEME=rootless

export TARGET ?= iphone:clang:latest:14.0
export ARCHS ?= arm64 arm64e

export DEBUG ?= 0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DouyinLiquidGlass

DouyinLiquidGlass_FILES = Tweak.x DYGlassView.m DYGlassInjector.m DYPrefsSupport.m
DouyinLiquidGlass_CFLAGS = -fobjc-arc -I.
DouyinLiquidGlass_FRAMEWORKS = UIKit QuartzCore CoreGraphics

include $(THEOS)/makefiles/tweak.mk

# 设置面板（下一版再加回；当前先只编核心 tweak，降低编译风险）
#SUBPROJECTS += Prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
