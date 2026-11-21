include_guard(GLOBAL)

# Optional portable video decoders. The target is intentionally independent of
# Media so the caller can wire protocol codec selection without changing this
# adapter's packet contract.

if(NOT TARGET rincast-extra-video)
  include(FetchContent)
  include(ExternalProject)
  find_package(Python3 COMPONENTS Interpreter REQUIRED)

  FetchContent_Declare(
    rincast_dav1d
    URL https://downloads.videolan.org/pub/videolan/dav1d/1.5.5/dav1d-1.5.5.tar.xz
    URL_HASH SHA256=ca96b1d0ba3f01f55de7231d775892b64994ba061aaeeaaa4f662a390b3abf9e
    TLS_VERIFY ON
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  )
  if(POLICY CMP0169)
    cmake_policy(PUSH)
    cmake_policy(SET CMP0169 OLD)
  endif()
  FetchContent_Populate(rincast_dav1d)
  if(POLICY CMP0169)
    cmake_policy(POP)
  endif()

  set(RINCAST_DAV1D_VERSION 1.5.5 CACHE INTERNAL "Pinned dav1d release")
  set(RINCAST_DAV1D_COMMIT 6c7bee685677fd997a431302be4fea8ea4017606 CACHE INTERNAL
    "Commit corresponding to the pinned dav1d release")
  set(RINCAST_DAV1D_LICENSE_FILE "${rincast_dav1d_SOURCE_DIR}/COPYING" CACHE INTERNAL
    "Pinned dav1d BSD-2-Clause license text")
  set(RINCAST_DAV1D_LICENSE_OUTPUT
    "${CMAKE_CURRENT_BINARY_DIR}/licenses/dav1d.txt" CACHE INTERNAL
    "dav1d license copy generated in the native build")
  file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/licenses")
  configure_file("${RINCAST_DAV1D_LICENSE_FILE}"
    "${RINCAST_DAV1D_LICENSE_OUTPUT}" COPYONLY)

  find_program(RINCAST_NINJA_EXECUTABLE NAMES ninja ninja.exe)
  if(NOT RINCAST_NINJA_EXECUTABLE AND CMAKE_MAKE_PROGRAM MATCHES "ninja([.]exe)?$")
    set(RINCAST_NINJA_EXECUTABLE "${CMAKE_MAKE_PROGRAM}")
  endif()
  if(NOT RINCAST_NINJA_EXECUTABLE)
    message(FATAL_ERROR "RinCast AV1 requires Ninja to build pinned dav1d")
  endif()

  find_program(RINCAST_MESON_EXECUTABLE NAMES meson meson.py)
  if(RINCAST_MESON_EXECUTABLE)
    set(_rincast_meson_command "${RINCAST_MESON_EXECUTABLE}")
    set(_rincast_meson_pythonpath "")
  else()
    FetchContent_Declare(
      rincast_meson
      URL https://files.pythonhosted.org/packages/source/m/meson/meson-1.10.1.tar.gz
      URL_HASH SHA256=c42296f12db316a4515b9375a5df330f2e751ccdd4f608430d41d7d6210e4317
      DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    )
    if(POLICY CMP0169)
      cmake_policy(PUSH)
      cmake_policy(SET CMP0169 OLD)
    endif()
    FetchContent_Populate(rincast_meson)
    if(POLICY CMP0169)
      cmake_policy(POP)
    endif()
    set(_rincast_meson_command "${Python3_EXECUTABLE}" -m mesonbuild.mesonmain)
    set(_rincast_meson_pythonpath "${rincast_meson_SOURCE_DIR}")
  endif()

  set(_rincast_dav1d_build "${CMAKE_CURRENT_BINARY_DIR}/dav1d-build")
  set(_rincast_dav1d_install "${CMAKE_CURRENT_BINARY_DIR}/dav1d-install")
  set(_rincast_dav1d_library "${_rincast_dav1d_install}/lib/libdav1d.a")

  # Meson reads NINJA directly. Passing PATH through ExternalProject would
  # split Windows' semicolon-separated value into separate command arguments.
  set(_rincast_meson_env "${CMAKE_COMMAND}" -E env "NINJA=${RINCAST_NINJA_EXECUTABLE}")
  if(_rincast_meson_pythonpath)
    list(APPEND _rincast_meson_env "PYTHONPATH=${_rincast_meson_pythonpath}")
  endif()

  function(_rincast_meson_quote OUTPUT VALUE)
    string(REPLACE "\\" "/" VALUE "${VALUE}")
    string(REPLACE "'" "\\'" VALUE "${VALUE}")
    set(${OUTPUT} "'${VALUE}'" PARENT_SCOPE)
  endfunction()

  function(_rincast_meson_array OUTPUT)
    set(_items "")
    foreach(_value IN LISTS ARGN)
      _rincast_meson_quote(_quoted "${_value}")
      string(APPEND _items "${_quoted}, ")
    endforeach()
    set(${OUTPUT} "[${_items}]" PARENT_SCOPE)
  endfunction()

  set(_rincast_dav1d_archs "${CMAKE_OSX_ARCHITECTURES}")
  if(_rincast_dav1d_archs)
    list(LENGTH _rincast_dav1d_archs _rincast_arch_count)
    if(_rincast_arch_count GREATER 1)
      message(FATAL_ERROR
        "rincast-extra-video builds one architecture per CMake hook. "
        "Configure ${_rincast_dav1d_archs} as separate builds.")
    endif()
    set(_rincast_target_cpu "${CMAKE_OSX_ARCHITECTURES}")
  else()
    set(_rincast_target_cpu "${CMAKE_SYSTEM_PROCESSOR}")
  endif()
  if(NOT _rincast_target_cpu)
    set(_rincast_target_cpu "${CMAKE_HOST_SYSTEM_PROCESSOR}")
  endif()
  string(TOLOWER "${_rincast_target_cpu}" _rincast_target_cpu)

  if(_rincast_target_cpu MATCHES "^(aarch64|arm64)$")
    set(_rincast_cpu_family aarch64)
    set(_rincast_cpu arm64)
  elseif(_rincast_target_cpu MATCHES "^(x86_64|amd64)$")
    set(_rincast_cpu_family x86_64)
    set(_rincast_cpu x86_64)
  elseif(_rincast_target_cpu MATCHES "^(i[3-6]86|x86)$")
    set(_rincast_cpu_family x86)
    set(_rincast_cpu x86)
  elseif(_rincast_target_cpu MATCHES "^arm")
    set(_rincast_cpu_family arm)
    set(_rincast_cpu armv7)
  elseif(_rincast_target_cpu MATCHES "^riscv64")
    set(_rincast_cpu_family riscv64)
    set(_rincast_cpu riscv64)
  else()
    message(FATAL_ERROR "Unsupported dav1d target processor: ${_rincast_target_cpu}")
  endif()

  if(WIN32)
    set(_rincast_meson_system windows)
  elseif(ANDROID)
    set(_rincast_meson_system android)
  elseif(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(_rincast_meson_system ios)
  elseif(APPLE)
    set(_rincast_meson_system darwin)
  elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(_rincast_meson_system linux)
  else()
    string(TOLOWER "${CMAKE_SYSTEM_NAME}" _rincast_meson_system)
  endif()

  set(_rincast_c_args)
  separate_arguments(_rincast_c_args NATIVE_COMMAND
    "${CMAKE_C_FLAGS} ${CMAKE_C_FLAGS_RELEASE}")
  set(_rincast_link_args)
  separate_arguments(_rincast_link_args NATIVE_COMMAND
    "${CMAKE_EXE_LINKER_FLAGS} ${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
  list(JOIN _rincast_c_args " " _rincast_c_args_joined)
  list(JOIN _rincast_link_args " " _rincast_link_args_joined)

  set(_rincast_platform_args)
  if(ANDROID)
    string(REGEX REPLACE "^android-" "" _rincast_android_api "${ANDROID_PLATFORM}")
    if(ANDROID_ABI STREQUAL "arm64-v8a")
      set(_rincast_android_triple "aarch64-none-linux-android${_rincast_android_api}")
    elseif(ANDROID_ABI STREQUAL "armeabi-v7a")
      set(_rincast_android_triple "armv7a-none-linux-androideabi${_rincast_android_api}")
    elseif(ANDROID_ABI STREQUAL "x86")
      set(_rincast_android_triple "i686-none-linux-android${_rincast_android_api}")
    elseif(ANDROID_ABI STREQUAL "x86_64")
      set(_rincast_android_triple "x86_64-none-linux-android${_rincast_android_api}")
    else()
      message(FATAL_ERROR "Unsupported Android ABI for dav1d: ${ANDROID_ABI}")
    endif()
    list(APPEND _rincast_platform_args "--target=${_rincast_android_triple}")
    if(CMAKE_SYSROOT)
      set(_rincast_android_sysroot "${CMAKE_SYSROOT}")
    else()
      get_filename_component(_rincast_clang_bin "${CMAKE_C_COMPILER}" DIRECTORY)
      get_filename_component(_rincast_llvm_root "${_rincast_clang_bin}" DIRECTORY)
      set(_rincast_android_sysroot "${_rincast_llvm_root}/sysroot")
    endif()
    list(APPEND _rincast_platform_args "--sysroot=${_rincast_android_sysroot}")
  else()
    if(CMAKE_C_COMPILER_TARGET)
      list(APPEND _rincast_platform_args "--target=${CMAKE_C_COMPILER_TARGET}")
    endif()
    if(CMAKE_SYSROOT AND NOT _rincast_c_args_joined MATCHES "(^| )--sysroot=")
      list(APPEND _rincast_platform_args "--sysroot=${CMAKE_SYSROOT}")
    endif()
    if(APPLE)
      if(CMAKE_OSX_SYSROOT AND NOT _rincast_c_args_joined MATCHES "(^| )-isysroot ")
        list(APPEND _rincast_platform_args "-isysroot" "${CMAKE_OSX_SYSROOT}")
      endif()
      foreach(_arch IN LISTS CMAKE_OSX_ARCHITECTURES)
        if(NOT _rincast_c_args_joined MATCHES "(^| )-arch ${_arch}( |$)")
          list(APPEND _rincast_platform_args "-arch" "${_arch}")
        endif()
      endforeach()
    endif()
  endif()
  list(APPEND _rincast_c_args ${_rincast_platform_args})
  list(APPEND _rincast_link_args ${_rincast_platform_args})

  set(_rincast_c_compiler_list "${CMAKE_C_COMPILER}")
  if(CMAKE_C_COMPILER_ARG1)
    list(APPEND _rincast_c_compiler_list "${CMAKE_C_COMPILER_ARG1}")
  endif()
  _rincast_meson_array(_rincast_c_compiler_meson ${_rincast_c_compiler_list})
  if(CMAKE_C_COMPILER_AR)
    _rincast_meson_array(_rincast_ar_meson "${CMAKE_C_COMPILER_AR}")
  elseif(CMAKE_AR)
    _rincast_meson_array(_rincast_ar_meson "${CMAKE_AR}")
  else()
    set(_rincast_ar_meson "")
  endif()
  if(CMAKE_C_COMPILER_RANLIB)
    _rincast_meson_array(_rincast_ranlib_meson "${CMAKE_C_COMPILER_RANLIB}")
  elseif(CMAKE_RANLIB AND NOT CMAKE_RANLIB STREQUAL ":")
    _rincast_meson_array(_rincast_ranlib_meson "${CMAKE_RANLIB}")
  else()
    set(_rincast_ranlib_meson "")
  endif()
  if(CMAKE_STRIP)
    _rincast_meson_array(_rincast_strip_meson "${CMAKE_STRIP}")
  else()
    set(_rincast_strip_meson "")
  endif()
  _rincast_meson_array(_rincast_c_args_meson ${_rincast_c_args})
  _rincast_meson_array(_rincast_link_args_meson ${_rincast_link_args})

  set(_rincast_cross_file "${CMAKE_CURRENT_BINARY_DIR}/dav1d-cross.ini")
  set(_rincast_cross_contents
"# Generated by cmake/ExtraVideo.cmake for the current Native Asset target.\n")
  string(APPEND _rincast_cross_contents
"[binaries]\nc = ${_rincast_c_compiler_meson}\n")
  if(_rincast_ar_meson)
    string(APPEND _rincast_cross_contents "ar = ${_rincast_ar_meson}\n")
  endif()
  if(_rincast_ranlib_meson)
    string(APPEND _rincast_cross_contents "ranlib = ${_rincast_ranlib_meson}\n")
  endif()
  if(_rincast_strip_meson)
    string(APPEND _rincast_cross_contents "strip = ${_rincast_strip_meson}\n")
  endif()
  string(APPEND _rincast_cross_contents
"\n[properties]\nneeds_exe_wrapper = true\n"
"\n[built-in options]\nc_args = ${_rincast_c_args_meson}\n"
"c_link_args = ${_rincast_link_args_meson}\n"
"\n[host_machine]\nsystem = '${_rincast_meson_system}'\n"
"cpu_family = '${_rincast_cpu_family}'\ncpu = '${_rincast_cpu}'\n"
"endian = 'little'\n")
  file(WRITE "${_rincast_cross_file}" "${_rincast_cross_contents}")

  set(RINCAST_DAV1D_ENABLE_ASM OFF CACHE BOOL
    "Enable dav1d assembly; requires a working target assembler")
  if(RINCAST_DAV1D_ENABLE_ASM)
    set(_rincast_dav1d_asm true)
  else()
    set(_rincast_dav1d_asm false)
  endif()
  set(_rincast_dav1d_runtime_args)
  if(MSVC)
    # RinCast and all pinned native dependencies use the static MSVC runtime.
    list(APPEND _rincast_dav1d_runtime_args -Db_vscrt=mt)
  endif()

  ExternalProject_Add(rincast_dav1d_external
    PREFIX "${CMAKE_CURRENT_BINARY_DIR}/dav1d-external"
    SOURCE_DIR "${rincast_dav1d_SOURCE_DIR}"
    BINARY_DIR "${_rincast_dav1d_build}"
    INSTALL_DIR "${_rincast_dav1d_install}"
    CONFIGURE_COMMAND ${_rincast_meson_env} ${_rincast_meson_command}
      setup "${_rincast_dav1d_build}" "${rincast_dav1d_SOURCE_DIR}"
      --wipe --backend=ninja --buildtype=release --default-library=static
      --cross-file "${_rincast_cross_file}"
      --prefix "${_rincast_dav1d_install}" --libdir lib
      -Denable_asm=${_rincast_dav1d_asm}
      -Denable_tools=false -Denable_tests=false -Denable_examples=false
      -Denable_docs=false -Dbitdepths=8,16 -Dlogging=true
      ${_rincast_dav1d_runtime_args}
    BUILD_COMMAND ${_rincast_meson_env} ${_rincast_meson_command}
      compile -C "${_rincast_dav1d_build}"
    INSTALL_COMMAND ${_rincast_meson_env} ${_rincast_meson_command}
      install -C "${_rincast_dav1d_build}"
    BUILD_BYPRODUCTS "${_rincast_dav1d_library}"
    USES_TERMINAL_CONFIGURE TRUE
    USES_TERMINAL_BUILD TRUE
    USES_TERMINAL_INSTALL TRUE
  )
  ExternalProject_Add_StepDependencies(rincast_dav1d_external configure
    "${_rincast_cross_file}")

  add_library(rincast-dav1d STATIC IMPORTED GLOBAL)
  set_target_properties(rincast-dav1d PROPERTIES
    IMPORTED_LOCATION "${_rincast_dav1d_library}"
    INTERFACE_INCLUDE_DIRECTORIES "${rincast_dav1d_SOURCE_DIR}/include"
  )
  add_dependencies(rincast-dav1d rincast_dav1d_external)

  if(TARGET libyuv)
    set(_rincast_libyuv_target libyuv)
  elseif(TARGET yuv)
    set(_rincast_libyuv_target yuv)
  else()
    message(FATAL_ERROR "rincast-extra-video requires the existing libyuv target")
  endif()

  add_library(rincast-extra-video STATIC
    "${CMAKE_CURRENT_LIST_DIR}/../src/extra_video.cpp")
  add_library(RinCast::ExtraVideo ALIAS rincast-extra-video)
  target_compile_features(rincast-extra-video PRIVATE cxx_std_20)
  target_include_directories(rincast-extra-video
    PUBLIC "${CMAKE_CURRENT_LIST_DIR}/../src")
  target_link_libraries(rincast-extra-video
    PRIVATE rincast-dav1d ${_rincast_libyuv_target} Threads::Threads)
  set_target_properties(rincast-extra-video PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    FOLDER third_party)
  if(MSVC)
    target_compile_options(rincast-extra-video PRIVATE /W4 /utf-8)
  else()
    target_compile_options(rincast-extra-video PRIVATE -Wall -Wextra -Wpedantic)
  endif()

  install(FILES "${RINCAST_DAV1D_LICENSE_FILE}"
    DESTINATION licenses RENAME dav1d.txt)

  # Static targets propagate their archive into rincast_backend. CMake's
  # imported-target dependency ensures dav1d is installed before it links.
endif()
