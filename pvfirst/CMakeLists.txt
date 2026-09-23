cmake_minimum_required(VERSION 3.16)

project(pvfirst)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(CURL REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(SIMGRID REQUIRED IMPORTED_TARGET simgrid)

file(GLOB_RECURSE SOURCES
    src/*.cpp
    src/energy/*.cpp
    src/model/*.cpp
    src/sensors/*.cpp
    src/simulation/*.cpp
)

add_executable(pvfirst ${SOURCES})

target_include_directories(pvfirst PRIVATE
    src
    ${CURL_INCLUDE_DIRS}
)

target_link_libraries(pvfirst PRIVATE
    CURL::libcurl
    PkgConfig::SIMGRID
)

file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/simgrid)

configure_file(
    ${CMAKE_SOURCE_DIR}/simgrid/platform.xml
    ${CMAKE_BINARY_DIR}/simgrid/platform.xml
    COPYONLY
)