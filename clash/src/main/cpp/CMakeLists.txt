cmake_minimum_required(VERSION 3.5)
project(ClashNative C CXX)

set(NATIVE_CORE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/native-core)
set(NATIVE_CORE_LIB ${NATIVE_CORE_DIR}/libclashhm_native_core.a)
set(NATIVE_CORE_HEADER ${NATIVE_CORE_DIR}/native_core.h)
set(NATIVE_CORE_SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../native-core)
option(CLASHHM_AUTO_BUILD_NATIVE_CORE "Build ClashHM Rust native-core when the Rust/OHOS toolchain is available" ON)

set(CLASHHM_NATIVE_CORE_SOURCES
    clash_bridge.cpp
    ohos_compat_shim.cpp
)

set(CLASHHM_OHOS_SYSROOT ${CMAKE_SYSROOT})
if(NOT CLASHHM_OHOS_SYSROOT AND OHOS_SDK_NATIVE)
    set(CLASHHM_OHOS_SYSROOT ${OHOS_SDK_NATIVE}/sysroot)
endif()
if(NOT CLASHHM_OHOS_SYSROOT AND HMOS_SDK_NATIVE)
    get_filename_component(CLASHHM_HMOS_NATIVE_PARENT ${HMOS_SDK_NATIVE}/../.. ABSOLUTE)
    set(CLASHHM_OHOS_SYSROOT ${CLASHHM_HMOS_NATIVE_PARENT}/openharmony/native/sysroot)
endif()

set(CLASHHM_OHOS_AR ${CMAKE_AR})
if(NOT CLASHHM_OHOS_AR AND CMAKE_C_COMPILER)
    get_filename_component(CLASHHM_C_COMPILER_DIR ${CMAKE_C_COMPILER} DIRECTORY)
    find_program(CLASHHM_OHOS_AR
        NAMES llvm-ar ar
        HINTS ${CLASHHM_C_COMPILER_DIR}
        NO_DEFAULT_PATH)
endif()

if(NOT EXISTS ${NATIVE_CORE_LIB} AND CLASHHM_AUTO_BUILD_NATIVE_CORE AND EXISTS ${NATIVE_CORE_SOURCE_DIR}/build-ohos.sh)
    find_program(CLASHHM_BASH
        NAMES bash
        HINTS /bin /usr/bin /data/app/bin)
    find_program(CLASHHM_CARGO
        NAMES cargo
        HINTS
            $ENV{HOME}/.cargo/bin
            /storage/Users/currentUser/.cargo/bin
            /root/.cargo/bin
            /usr/local/bin
            /usr/bin)
    find_program(CLASHHM_RUSTUP
        NAMES rustup
        HINTS
            $ENV{HOME}/.cargo/bin
            /storage/Users/currentUser/.cargo/bin
            /root/.cargo/bin
            /usr/local/bin
            /usr/bin)
    message(STATUS "ClashHM native-core auto build probe: bash=${CLASHHM_BASH}; cargo=${CLASHHM_CARGO}; rustup=${CLASHHM_RUSTUP}; sysroot=${CLASHHM_OHOS_SYSROOT}; clang=${CMAKE_C_COMPILER}; ar=${CLASHHM_OHOS_AR}")
    if(CLASHHM_BASH AND CLASHHM_CARGO AND CLASHHM_OHOS_SYSROOT AND CMAKE_C_COMPILER AND CLASHHM_OHOS_AR)
        message(STATUS "ClashHM native-core: attempting Rust build with cargo=${CLASHHM_CARGO}")
        execute_process(
            COMMAND ${CMAKE_COMMAND} -E env
                OHOS_SYSROOT=${CLASHHM_OHOS_SYSROOT}
                OHOS_CLANG=${CMAKE_C_COMPILER}
                OHOS_AR=${CLASHHM_OHOS_AR}
                CARGO=${CLASHHM_CARGO}
                RUSTUP=${CLASHHM_RUSTUP}
                ${CLASHHM_BASH} ${NATIVE_CORE_SOURCE_DIR}/build-ohos.sh
            WORKING_DIRECTORY ${NATIVE_CORE_SOURCE_DIR}
            RESULT_VARIABLE CLASHHM_NATIVE_CORE_BUILD_RESULT
            OUTPUT_VARIABLE CLASHHM_NATIVE_CORE_BUILD_OUTPUT
            ERROR_VARIABLE CLASHHM_NATIVE_CORE_BUILD_ERROR
        )
        if(NOT CLASHHM_NATIVE_CORE_BUILD_RESULT EQUAL 0)
            message(WARNING "ClashHM native-core build failed. ${CLASHHM_NATIVE_CORE_BUILD_ERROR}")
        else()
            message(STATUS "ClashHM native-core build completed")
        endif()
    else()
        message(STATUS "ClashHM native-core auto build skipped: missing bash/cargo/OHOS toolchain component")
    endif()
endif()

if(EXISTS ${NATIVE_CORE_LIB} AND EXISTS ${NATIVE_CORE_HEADER})
    message(STATUS "ClashHM Rust native-core enabled: ${NATIVE_CORE_LIB}")
    add_library(clash SHARED ${CLASHHM_NATIVE_CORE_SOURCES})
    target_include_directories(clash PRIVATE ${NATIVE_CORE_DIR})
    target_compile_definitions(clash PRIVATE CLASHHM_HAS_RUST_NATIVE_CORE=1)
    target_link_libraries(clash PUBLIC ${NATIVE_CORE_LIB})
else()
    message(WARNING "ClashHM Rust native-core artifact is missing. Building C++ Extension native-core compatibility layer so DevEco can produce a HAP. Auto build probe: bash=${CLASHHM_BASH}; cargo=${CLASHHM_CARGO}; rustup=${CLASHHM_RUSTUP}; sysroot=${CLASHHM_OHOS_SYSROOT}; clang=${CMAKE_C_COMPILER}; ar=${CLASHHM_OHOS_AR}. Runtime VPN start will report native_core_cpp_compat until the Rust staticlib is available.")
    add_library(clash SHARED
        ${CLASHHM_NATIVE_CORE_SOURCES}
        native_core_compat.cpp
    )
    target_include_directories(clash PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
endif()

target_link_libraries(clash PUBLIC
    libace_napi.z.so
    pthread
)
