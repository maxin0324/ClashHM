cmake_minimum_required(VERSION 3.4.1)
project(ClashNative)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

add_library(mihomo SHARED IMPORTED)
set_target_properties(mihomo PROPERTIES IMPORTED_LOCATION
    ${CMAKE_CURRENT_SOURCE_DIR}/../libs/${OHOS_ARCH}/libmihomo.so)

add_library(clash SHARED
    clash_bridge.cpp
)

target_link_libraries(clash PUBLIC
    libace_napi.z.so
    mihomo
)
