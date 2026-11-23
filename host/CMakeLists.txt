cmake_minimum_required(VERSION 3.24)
project(FogShotStreamer LANGUAGES C CXX)

if(NOT WIN32 AND NOT APPLE)
  message(FATAL_ERROR "This version of RinCast supplies desktop capture on Windows and macOS.")
endif()

include(FetchContent)
FetchContent_Declare(RinCastHost
  URL https://codeload.github.com/TheReal-Flo/RinCast/zip/10ebeb207a65fad7ea23ebdca038e59ccff2315b
  URL_HASH SHA256=71d30f893999b05fcd5f744c7d23639c429758683af9ef0709678523650dc476
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  SOURCE_SUBDIR fogshot-unused)
FetchContent_MakeAvailable(RinCastHost)

# Make changes only to the build directory's copy of the pinned archive.
set(upstream "${CMAKE_CURRENT_BINARY_DIR}/upstream")
file(COPY "${rincasthost_SOURCE_DIR}/" DESTINATION "${upstream}")
include(adapt_streamer.cmake)

if(WIN32)
  add_subdirectory("${upstream}/pc" rincast)
else()
  add_subdirectory("${upstream}/pc/mac" rincast)
endif()

get_target_property(origin rincast-streamer SOURCE_DIR)
get_target_property(original_sources rincast-streamer SOURCES)
set(sources "${CMAKE_CURRENT_SOURCE_DIR}/streamer_main.cpp")
foreach(source IN LISTS original_sources)
  if(source MATCHES "(^|/)(main|main_terminal)\\.cpp$")
    continue()
  endif()
  if(IS_ABSOLUTE "${source}")
    list(APPEND sources "${source}")
  else()
    list(APPEND sources "${origin}/${source}")
  endif()
endforeach()
set_target_properties(rincast-streamer PROPERTIES
  SOURCES "${sources}" WIN32_EXECUTABLE FALSE OUTPUT_NAME fogshot-streamer)
if(WIN32)
  target_compile_definitions(rincast-streamer PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
  # The Flutter UI replaces WebView2. The vendored loader is x64 only.
  set_target_properties(rincast-streamer PROPERTIES LINK_LIBRARIES "rincast-core;version")
endif()
install(TARGETS rincast-streamer RUNTIME DESTINATION .)
