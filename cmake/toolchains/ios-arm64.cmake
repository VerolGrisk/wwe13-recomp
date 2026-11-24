# iOS / iPadOS (arm64, device) toolchain for ReXGlue and WWE '13 Recomp, used by tools/build-ios.sh.
# Needs Xcode with the iOS SDK. Builds for devices only (no simulator: the simulator's GPU path is
# not representative and the guest memory layout is untested there).
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_SYSROOT iphoneos)
if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
  set(CMAKE_OSX_DEPLOYMENT_TARGET 17.0)
endif()
# CMake's compiler checks cannot run an unsigned iOS executable; test with static libraries.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
# Signing happens after the build (ad-hoc in build-ios.sh, then by the user's signing service).
set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
