cmake_minimum_required(VERSION 3.4.1)
project(ClashNative)

add_library(clash SHARED
    clash_bridge.cpp
)

target_link_libraries(clash PUBLIC
    libace_napi.z.so
)
