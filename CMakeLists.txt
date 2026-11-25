cmake_minimum_required(VERSION 3.25)
project(wwe13 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(generated/rexglue.cmake)

find_package(Git QUIET)
set(WWE13_BUILD_COMMIT unknown)
set(WWE13_BUILD_DIRTY unknown)
set(WWE13_SDK_COMMIT unknown)
set(WWE13_SDK_DIRTY unknown)
if(GIT_FOUND)
  execute_process(COMMAND "${GIT_EXECUTABLE}" rev-parse --short=12 HEAD
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    OUTPUT_VARIABLE WWE13_BUILD_COMMIT OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE WWE13_GIT_RESULT ERROR_QUIET)
  if(NOT WWE13_GIT_RESULT EQUAL 0)
    set(WWE13_BUILD_COMMIT unknown)
  else()
    execute_process(COMMAND "${GIT_EXECUTABLE}" status --porcelain
      WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
      OUTPUT_VARIABLE WWE13_GIT_STATUS OUTPUT_STRIP_TRAILING_WHITESPACE
      RESULT_VARIABLE WWE13_GIT_STATUS_RESULT ERROR_QUIET)
    if(WWE13_GIT_STATUS_RESULT EQUAL 0)
      if(WWE13_GIT_STATUS STREQUAL "")
        set(WWE13_BUILD_DIRTY no)
      else()
        set(WWE13_BUILD_DIRTY yes)
      endif()
    endif()
  endif()

  if(NOT DEFINED WWE13_SDK_ROOT OR WWE13_SDK_ROOT STREQUAL "")
    set(WWE13_SDK_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../tools/rexglue")
  endif()
  execute_process(COMMAND "${GIT_EXECUTABLE}" rev-parse --short=12 HEAD
    WORKING_DIRECTORY "${WWE13_SDK_ROOT}"
    OUTPUT_VARIABLE WWE13_SDK_COMMIT OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE WWE13_SDK_GIT_RESULT ERROR_QUIET)
  if(WWE13_SDK_GIT_RESULT EQUAL 0)
    execute_process(COMMAND "${GIT_EXECUTABLE}" status --porcelain
      WORKING_DIRECTORY "${WWE13_SDK_ROOT}"
      OUTPUT_VARIABLE WWE13_SDK_GIT_STATUS OUTPUT_STRIP_TRAILING_WHITESPACE
      RESULT_VARIABLE WWE13_SDK_GIT_STATUS_RESULT ERROR_QUIET)
    if(WWE13_SDK_GIT_STATUS_RESULT EQUAL 0)
      if(WWE13_SDK_GIT_STATUS STREQUAL "")
        set(WWE13_SDK_DIRTY no)
      else()
        set(WWE13_SDK_DIRTY yes)
      endif()
    endif()
  endif()
endif()
include(cmake/wwe13_version.cmake)
string(TIMESTAMP WWE13_BUILD_DATE "%Y-%m-%dT%H:%M:%SZ" UTC)
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated")
configure_file(src/wwe13_build_info.h.in
  "${CMAKE_CURRENT_BINARY_DIR}/generated/wwe13_build_info.h" @ONLY)

add_executable(wwe13
  src/main.cpp
  src/game_version_check.cpp
  src/release_diagnostics.cpp
  src/single_instance.cpp
  src/dlist_tripwire.cpp
  src/perf_overlay.cpp
  src/thread_profiler.cpp
  src/bink_oracle.cpp
  src/resolve_coherency.cpp
  src/present_interval.cpp
  src/cloth_handshake.cpp
  src/res_probe.cpp
  src/scene_resolution.cpp
  src/text_entry_keyboard.cpp
  src/scene_aa.cpp
  src/xmp_audio_probe.cpp
  src/shader_cache_seed.cpp)
target_include_directories(wwe13 PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/generated")
rexglue_setup_target(wwe13)
if(WIN32)
  target_link_libraries(wwe13 PRIVATE advapi32)
  # Link map next to the exe: symbol -> object resolution for Windows-only link checks.
  target_link_options(wwe13 PRIVATE "LINKER:/map:$<TARGET_FILE_DIR:wwe13>/wwe13.map")
endif()
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  # iOS / iPadOS: an app bundle with the game's Info.plist (landscape, full screen, Documents in
  # the Files app) and MoltenVK embedded (iOS has no Vulkan loader). tools/build-ios.sh signs it
  # ad-hoc with cmake/ios/app.entitlements and packages the IPA.
  set(WWE13_IOS_MOLTENVK_FRAMEWORK "" CACHE PATH "ios-arm64 MoltenVK.framework to embed")
  set_target_properties(wwe13 PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/cmake/ios/Info.plist.in"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.wwe13recomp.game"
    MACOSX_BUNDLE_BUNDLE_NAME "WWE 13"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0"
    MACOSX_BUNDLE_BUNDLE_VERSION "1"
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH "@executable_path/Frameworks")
  if(WWE13_IOS_MOLTENVK_FRAMEWORK)
    add_custom_command(TARGET wwe13 POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_DIR:wwe13>/Frameworks"
      COMMAND ${CMAKE_COMMAND} -E copy_directory "${WWE13_IOS_MOLTENVK_FRAMEWORK}"
              "$<TARGET_BUNDLE_DIR:wwe13>/Frameworks/MoltenVK.framework"
      VERBATIM)
  else()
    message(WARNING "WWE13_IOS_MOLTENVK_FRAMEWORK is not set: the app will find no Vulkan driver")
  endif()
endif()
