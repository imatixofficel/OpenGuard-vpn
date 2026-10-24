APP_ABI := all
APP_PLATFORM := android-16

# 16 KB page alignment (Android 15+ 16 KB-page devices)
APP_LDFLAGS := -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384
