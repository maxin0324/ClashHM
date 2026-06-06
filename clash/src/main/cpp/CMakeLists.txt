cmake_minimum_required(VERSION 3.5)
project(ClashNative C CXX ASM)

set(HEV_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/third_party/hev-socks5-tunnel)

file(GLOB HEV_TUNNEL_SOURCES
    ${HEV_ROOT}/src/*.c
    ${HEV_ROOT}/src/misc/*.c
    ${HEV_ROOT}/src/core/src/*.c
    ${HEV_ROOT}/third-part/yaml/src/*.c
)
list(REMOVE_ITEM HEV_TUNNEL_SOURCES
    ${HEV_ROOT}/src/hev-jni.c
    ${HEV_ROOT}/src/hev-tunnel-freebsd.c
    ${HEV_ROOT}/src/hev-tunnel-macos.c
    ${HEV_ROOT}/src/hev-tunnel-netbsd.c
    ${HEV_ROOT}/src/hev-tunnel-windows.c
    ${HEV_ROOT}/src/core/src/hev-rbtree.c
    ${HEV_ROOT}/src/misc/hev-list.c
    ${HEV_ROOT}/src/misc/hev-wintun.c
)

file(GLOB_RECURSE HEV_TASK_SOURCES
    ${HEV_ROOT}/third-part/hev-task-system/src/*.c
)
list(FILTER HEV_TASK_SOURCES EXCLUDE REGEX "/src/kern/io/hev-task-io-reactor-iocp\\.c$")

file(GLOB_RECURSE LWIP_SOURCES
    ${HEV_ROOT}/third-part/lwip/src/*.c
)
list(FILTER LWIP_SOURCES EXCLUDE REGEX "/src/ports/win32/")

add_library(clash SHARED
    clash_bridge.cpp
    ${HEV_TUNNEL_SOURCES}
    ${HEV_TASK_SOURCES}
    ${LWIP_SOURCES}
    ${HEV_ROOT}/third-part/hev-task-system/src/kern/task/hev-task-execute.S
)

target_include_directories(clash PRIVATE
    ${HEV_ROOT}/src
    ${HEV_ROOT}/src/misc
    ${HEV_ROOT}/src/core/src
    ${HEV_ROOT}/src/core/include
    ${HEV_ROOT}/third-part/yaml/src
    ${HEV_ROOT}/third-part/yaml/include
    ${HEV_ROOT}/third-part/lwip/src/include
    ${HEV_ROOT}/third-part/lwip/src/ports/include
    ${HEV_ROOT}/third-part/hev-task-system/src
    ${HEV_ROOT}/third-part/hev-task-system/include
)

target_compile_definitions(clash PRIVATE
    FD_SET_DEFINED
    SOCKLEN_T_DEFINED
    ENABLE_LIBRARY
    ENABLE_STACK_OVERFLOW_DETECTION
    ENABLE_MEMALLOC_SLICE
    ENABLE_IO_SPLICE_SYSCALL
    CONFIG_STACK_BACKEND=STACK_MMAP
    CONFIG_STACK_OVERFLOW_DETECTION=1
    CONFIG_MEMALLOC_SLICE_ALIGN=16
    CONFIG_MEMALLOC_SLICE_MAX_SIZE=4096
    CONFIG_MEMALLOC_SLICE_MAX_COUNT=1000
    CONFIG_SCHED_CLOCK=CLOCK_NONE
    COMMIT_ID="vendored"
    YAML_VERSION_MAJOR=0
    YAML_VERSION_MINOR=2
    YAML_VERSION_PATCH=5
    YAML_VERSION_STRING="0.2.5"
)

target_link_libraries(clash PUBLIC
    libace_napi.z.so
    pthread
)

# The full mihomo core runs in the UI process and is dlopen()ed by libclash.so.
# Keep the core beside libclash.so in the packaged native library directory.
add_custom_command(TARGET clash POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
    ${CMAKE_CURRENT_SOURCE_DIR}/../libs/arm64-v8a/libmihomo.so
    $<TARGET_FILE_DIR:clash>/libmihomo.so)
