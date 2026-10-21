cmake_minimum_required(VERSION 3.16)
project(tx_shim CXX)

# Path to the Textractor checkout (adjust if your layout differs).
set(TX_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/Textractor CACHE PATH "Textractor source root")

# Textractor's host sources reuse a precompiled header (target "pch") that is force-included
# into every file, so they don't #include everything themselves. Find the line
#     target_precompile_headers(pch ...)
# in Textractor's CMake files (likely the top-level CMakeLists.txt) and put the same
# headers here, e.g.  -DTX_PCH_HEADERS="include/common.h;include/const.h"
# Paths are relative to TX_ROOT. Leave empty only if the build works without it.
set(TX_PCH_HEADERS "include/common.h" CACHE STRING "Headers from Textractor's pch target (relative to TX_ROOT)")

# Same sources as Textractor's `add_library(host ...)`.
add_library(tx_shim SHARED
    tx_shim.cpp
    tx_find.cpp
    ${TX_ROOT}/host/host.cpp
    ${TX_ROOT}/host/textthread.cpp
    ${TX_ROOT}/host/hookcode.cpp
    ${TX_ROOT}/text.cpp          # string table; remove if the linker doesn't need it
)

# Legacy single-host library build. Use the root Zig build to package the dual
# architecture application, helper, and architecture-isolated hook DLLs.
if(CMAKE_SIZEOF_VOID_P EQUAL 8)
    target_sources(tx_shim PRIVATE tx_bridge.cpp)
endif()

target_include_directories(tx_shim PRIVATE
    ${TX_ROOT}/include
    ${TX_ROOT}/host
    ${TX_ROOT}
)

if(TX_PCH_HEADERS)
    set(_pch "")
    foreach(h ${TX_PCH_HEADERS})
        list(APPEND _pch ${TX_ROOT}/${h})
    endforeach()
    target_precompile_headers(tx_shim PRIVATE ${_pch})
endif()

# Mirrors the flags Textractor's top-level CMakeLists sets.
target_compile_features(tx_shim PRIVATE cxx_std_17)
target_compile_definitions(tx_shim PRIVATE
    TX_SHIM_BUILD
    UNICODE
    _UNICODE
    VERSION="embedded"
    ENGLISH          # text.cpp language selector; check text.cpp if it complains
)
if(MSVC)
    target_compile_options(tx_shim PRIVATE /MP /wd4018)
endif()

# If linking fails with unresolved Win32 symbols, add what CLI/CMakeLists.txt links, e.g.:
# target_link_libraries(tx_shim PRIVATE shell32 user32)