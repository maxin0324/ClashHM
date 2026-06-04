cmake_minimum_required(VERSION 3.5)
project(ClashNative)

add_library(clash SHARED
    clash_bridge.cpp
)

target_link_libraries(clash PUBLIC
    libace_napi.z.so
)

# Ensure libmihomo.so gets packaged into the HAP
# It will be loaded via dlopen at runtime, not linked at compile time
add_library(mihomo SHARED IMPORTED)
set_target_properties(mihomo PROPERTIES IMPORTED_LOCATION
    ${CMAKE_CURRENT_SOURCE_DIR}/../libs/arm64-v8a/libmihomo.so)

# Force CMake to include it in the output
add_custom_command(TARGET clash POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
    ${CMAKE_CURRENT_SOURCE_DIR}/../libs/arm64-v8a/libmihomo.so
    ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/libmihomo.so)
