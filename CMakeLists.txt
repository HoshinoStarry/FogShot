cmake_minimum_required(VERSION 3.24)
project(FogShot VERSION 0.1.0 LANGUAGES C CXX)

include(FetchContent)
find_package(Threads REQUIRED)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(MSVC)
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

FetchContent_Declare(RinCast
  URL https://codeload.github.com/TheReal-Flo/RinCast/zip/10ebeb207a65fad7ea23ebdca038e59ccff2315b
  URL_HASH SHA256=71d30f893999b05fcd5f744c7d23639c429758683af9ef0709678523650dc476
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  SOURCE_SUBDIR shared)
FetchContent_MakeAvailable(RinCast)
include(cmake/OpenH264.cmake)

add_library(rincast_backend SHARED src/bridge.cpp src/media.cpp src/session.cpp)
target_link_libraries(rincast_backend PRIVATE
  rincast-core openh264 libyuv rincast-miniaudio Threads::Threads)
set_target_properties(rincast_backend PROPERTIES
  CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON)
if(MSVC)
  target_compile_options(rincast_backend PRIVATE /utf-8)
endif()
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  target_compile_definitions(rincast_backend PRIVATE RINCAST_DISABLE_DISCOVERY)
endif()
install(TARGETS rincast_backend RUNTIME DESTINATION . LIBRARY DESTINATION .)
