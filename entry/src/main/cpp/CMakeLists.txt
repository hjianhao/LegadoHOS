cmake_minimum_required(VERSION 3.16)
project("quickjs_bridge")

# 设置 C/C++ 标准
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

# 计算项目根目录（从 entry/src/main/cpp/ 上溯到项目根）
set(PROJECT_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../../)

# QuickJS 源文件
set(QUICKJS_SRC ${PROJECT_ROOT}/libraries/quickjs/src)

# QuickJS 引擎源文件
list(APPEND QUICKJS_SOURCES
    ${QUICKJS_SRC}/quickjs.c
    ${QUICKJS_SRC}/quickjs-libc.c
    ${QUICKJS_SRC}/libregexp.c
    ${QUICKJS_SRC}/libunicode.c
    ${QUICKJS_SRC}/dtoa.c
    ${QUICKJS_SRC}/napi_bridge.cpp
)

# 包含目录
include_directories(
    ${QUICKJS_SRC}
)

# NAPI 头文件路径
include_directories(
    ${OHOS_SDK_NATIVE}/sysroot/usr/include
)

# 编译选项 (C)
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DCONFIG_BIGNUM -DCONFIG_VERSION='2024-01-13' -O2 -fno-strict-aliasing -fomit-frame-pointer -D_GNU_SOURCE")
# 编译选项 (C++)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O2 -fno-strict-aliasing -fomit-frame-pointer -D_GNU_SOURCE")

# 查找 NAPI 库
set(ACE_NAPI_LIB ${OHOS_SDK_NATIVE}/sysroot/usr/lib/aarch64-linux-ohos/libace_napi.z.so)

message(STATUS "PROJECT_ROOT: ${PROJECT_ROOT}")
message(STATUS "QUICKJS_SRC: ${QUICKJS_SRC}")
message(STATUS "OHOS_ARCH: ${OHOS_ARCH}")

# 构建共享库
add_library(quickjs_bridge SHARED ${QUICKJS_SOURCES})

# 链接库
target_link_libraries(quickjs_bridge
    PUBLIC
    ${ACE_NAPI_LIB}
    c++
    c
    m
    pthread
)

# 设置输出名称
set_target_properties(quickjs_bridge PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${PROJECT_ROOT}/libs/${OHOS_ARCH}"
    OUTPUT_NAME "quickjs_bridge"
)
