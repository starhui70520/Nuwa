cmake_minimum_required(VERSION 3.22)
project(NuwaAvif LANGUAGES C CXX)

include(FetchContent)
if(DEFINED PACKAGE_FIND_FILE)
  include(${PACKAGE_FIND_FILE})
endif()

# The SDK cross-compiles both ABIs. AOM generates its dispatch tables on the host.
find_package(Perl QUIET)
if(CMAKE_HOST_WIN32 AND NOT PERL_FOUND)
  find_package(Git REQUIRED)
  get_filename_component(git_bin "${GIT_EXECUTABLE}" DIRECTORY)
  find_program(PERL_EXECUTABLE perl HINTS "${git_bin}/../usr/bin"
    NO_CMAKE_FIND_ROOT_PATH REQUIRED)
endif()

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(AOM_TARGET_CPU generic CACHE STRING "" FORCE)
set(CONFIG_AV1_ENCODER 0 CACHE BOOL "" FORCE)
set(ENABLE_APPS OFF CACHE BOOL "" FORCE)
set(ENABLE_DOCS OFF CACHE BOOL "" FORCE)
set(ENABLE_EXAMPLES OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(ENABLE_TOOLS OFF CACHE BOOL "" FORCE)

FetchContent_Declare(aom
  URL https://storage.googleapis.com/aom-releases/libaom-3.15.3.tar.gz
  URL_HASH SHA256=12c01dc731ed7b5a999e28120b45bf58a002ba3435a4ba2cfbc1e084a27c9c04
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(aom)
target_include_directories(aom INTERFACE
  "$<BUILD_INTERFACE:${aom_SOURCE_DIR}>")

set(AVIF_CODEC_AOM SYSTEM CACHE STRING "" FORCE)
set(AVIF_CODEC_AOM_ENCODE OFF CACHE BOOL "" FORCE)
set(AVIF_LIBYUV OFF CACHE STRING "" FORCE)
set(AVIF_BUILD_APPS OFF CACHE BOOL "" FORCE)
set(AVIF_BUILD_TESTS OFF CACHE BOOL "" FORCE)
FetchContent_Declare(libavif
  URL https://codeload.github.com/AOMediaCodec/libavif/tar.gz/refs/tags/v1.4.2
  URL_HASH SHA256=2b645287340ba5a631d268b551dc2d72bd73ac33335962dd36dcdb6d8366921d
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(libavif)

add_library(nuwa_avif SHARED AvifDecoder.cpp)
target_compile_features(nuwa_avif PRIVATE cxx_std_17)
target_link_libraries(nuwa_avif PRIVATE avif libace_napi.z.so)
