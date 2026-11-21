include_guard(GLOBAL)

# The application only decodes, so this target contains OpenH264's decoder and
# common C/C++ sources. Architecture assembly is deliberately omitted: scalar
# fallbacks keep the same target buildable for all five supported platforms.
if(NOT TARGET openh264)
  include(FetchContent)
  find_package(Threads REQUIRED)

  FetchContent_Declare(
    rincast_openh264
    URL https://github.com/cisco/openh264/archive/652bdb7719f30b52b08e506645a7322ff1b2cc6f.tar.gz
    URL_HASH SHA256=7a060916a9fcb63ba51d83a4f2388660c0b58797be547c4fa5c52e8d65660a85
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  )

  # OpenH264 ships Make and Meson builds, not a CMake project. Populate the
  # pinned source and compile its published C/C++ lists directly.
  if(POLICY CMP0169)
    cmake_policy(PUSH)
    cmake_policy(SET CMP0169 OLD)
  endif()
  FetchContent_Populate(rincast_openh264)
  if(POLICY CMP0169)
    cmake_policy(POP)
  endif()

  set(_openh264 ${rincast_openh264_SOURCE_DIR}/codec)
  set(_openh264_common_sources
    ${_openh264}/common/src/common_tables.cpp
    ${_openh264}/common/src/copy_mb.cpp
    ${_openh264}/common/src/cpu.cpp
    ${_openh264}/common/src/crt_util_safe_x.cpp
    ${_openh264}/common/src/deblocking_common.cpp
    ${_openh264}/common/src/expand_pic.cpp
    ${_openh264}/common/src/intra_pred_common.cpp
    ${_openh264}/common/src/mc.cpp
    ${_openh264}/common/src/memory_align.cpp
    ${_openh264}/common/src/sad_common.cpp
    ${_openh264}/common/src/utils.cpp
    ${_openh264}/common/src/welsCodecTrace.cpp
    ${_openh264}/common/src/WelsTaskThread.cpp
    ${_openh264}/common/src/WelsThread.cpp
    ${_openh264}/common/src/WelsThreadLib.cpp
    ${_openh264}/common/src/WelsThreadPool.cpp
  )
  set(_openh264_decoder_sources
    ${_openh264}/decoder/core/src/au_parser.cpp
    ${_openh264}/decoder/core/src/bit_stream.cpp
    ${_openh264}/decoder/core/src/cabac_decoder.cpp
    ${_openh264}/decoder/core/src/deblocking.cpp
    ${_openh264}/decoder/core/src/decode_mb_aux.cpp
    ${_openh264}/decoder/core/src/decode_slice.cpp
    ${_openh264}/decoder/core/src/decoder.cpp
    ${_openh264}/decoder/core/src/decoder_core.cpp
    ${_openh264}/decoder/core/src/decoder_data_tables.cpp
    ${_openh264}/decoder/core/src/error_concealment.cpp
    ${_openh264}/decoder/core/src/fmo.cpp
    ${_openh264}/decoder/core/src/get_intra_predictor.cpp
    ${_openh264}/decoder/core/src/manage_dec_ref.cpp
    ${_openh264}/decoder/core/src/memmgr_nal_unit.cpp
    ${_openh264}/decoder/core/src/mv_pred.cpp
    ${_openh264}/decoder/core/src/parse_mb_syn_cabac.cpp
    ${_openh264}/decoder/core/src/parse_mb_syn_cavlc.cpp
    ${_openh264}/decoder/core/src/pic_queue.cpp
    ${_openh264}/decoder/core/src/rec_mb.cpp
    ${_openh264}/decoder/core/src/wels_decoder_thread.cpp
    ${_openh264}/decoder/plus/src/welsDecoderExt.cpp
  )

  add_library(openh264 STATIC
    ${_openh264_common_sources}
    ${_openh264_decoder_sources}
  )
  target_include_directories(openh264
    PUBLIC ${_openh264}/api/wels
    PRIVATE
      ${_openh264}/common/inc
      ${_openh264}/decoder/core/inc
      ${_openh264}/decoder/plus/inc
  )
  target_compile_features(openh264 PRIVATE c_std_99 cxx_std_11)
  target_link_libraries(openh264 PUBLIC Threads::Threads)
  set_target_properties(openh264 PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    FOLDER third_party
  )

  if(MSVC)
    target_compile_options(openh264 PRIVATE /W0)
    target_compile_definitions(openh264 PRIVATE _CRT_SECURE_NO_WARNINGS NOMINMAX WIN32_LEAN_AND_MEAN)
  else()
    target_compile_options(openh264 PRIVATE -w)
  endif()

  add_library(OpenH264::OpenH264 ALIAS openh264)
endif()

# Pinned header-only playback dependency. Full miniaudio is not needed because
# Opus packets are decoded by rincast-core before reaching this backend.
if(NOT TARGET rincast-miniaudio)
  include(FetchContent)

  FetchContent_Declare(
    rincast_miniaudio
    URL https://github.com/mackron/miniaudio/archive/877ea4a7c2601c7b0f2a44e83dfac42e6470fea6.tar.gz
    URL_HASH SHA256=b142cefa199ec27cfe77c5da7514d4a82fdc208444dd0abef947efeada14b60d
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  )
  if(POLICY CMP0169)
    cmake_policy(PUSH)
    cmake_policy(SET CMP0169 OLD)
  endif()
  FetchContent_Populate(rincast_miniaudio)
  if(POLICY CMP0169)
    cmake_policy(POP)
  endif()

  add_library(rincast-miniaudio INTERFACE)
  target_include_directories(rincast-miniaudio INTERFACE ${rincast_miniaudio_SOURCE_DIR})
  if(ANDROID)
    target_link_libraries(rincast-miniaudio INTERFACE android log)
  elseif(APPLE AND CMAKE_SYSTEM_NAME STREQUAL "iOS")
    target_link_libraries(rincast-miniaudio INTERFACE
      "-framework AVFoundation"
      "-framework AudioToolbox"
      "-framework CoreFoundation"
    )
  elseif(UNIX)
    find_package(Threads REQUIRED)
    target_link_libraries(rincast-miniaudio INTERFACE Threads::Threads ${CMAKE_DL_LIBS} m)
  endif()
endif()

# libyuv supplies the SIMD I420 -> BGRA conversion used by Media. Its top-level
# CMakeLists also declares tools and a shared library, so only the yuv target is
# brought into the build.
if(NOT TARGET yuv)
  include(FetchContent)

  FetchContent_Declare(
    rincast_libyuv
    GIT_REPOSITORY https://chromium.googlesource.com/libyuv/libyuv
    GIT_TAG 0ec9f68d82634f6f3414aaaf780e03f9edf002b3
    GIT_PROGRESS TRUE
  )
  if(POLICY CMP0169)
    cmake_policy(PUSH)
    cmake_policy(SET CMP0169 OLD)
  endif()
  FetchContent_Populate(rincast_libyuv)
  if(POLICY CMP0169)
    cmake_policy(POP)
  endif()

  set(UNIT_TEST OFF CACHE BOOL "" FORCE)
  set(LIBYUV_DISABLE_JPEG ON CACHE BOOL "" FORCE)
  add_subdirectory(${rincast_libyuv_SOURCE_DIR} ${rincast_libyuv_BINARY_DIR} EXCLUDE_FROM_ALL)
  target_include_directories(yuv PUBLIC ${rincast_libyuv_SOURCE_DIR}/include)
  set_target_properties(yuv PROPERTIES FOLDER third_party)
  if(MSVC)
    target_compile_options(yuv PRIVATE /W0)
  else()
    target_compile_options(yuv PRIVATE -w)
  endif()
  add_library(libyuv ALIAS yuv)
endif()
