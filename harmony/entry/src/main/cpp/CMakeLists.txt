cmake_minimum_required(VERSION 3.5.0)
project(nssft_harmony)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 协议核心与桌面测试工具共用，位于仓库根目录 core/
set(NSSFT_CORE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../core)

include_directories(${CMAKE_CURRENT_SOURCE_DIR} ${NSSFT_CORE_DIR})

add_library(entry SHARED
    napi_init.cpp
    session.cpp
    usb_host.cpp
    video_decoder.cpp
    video_enhancer.cpp
    vsync_monitor.cpp
    display_rate.cpp
    audio_player.cpp
    ${NSSFT_CORE_DIR}/sft_protocol.cpp
    ${NSSFT_CORE_DIR}/sft_receiver.cpp
    ${NSSFT_CORE_DIR}/sft_net_source.cpp
    ${NSSFT_CORE_DIR}/sft_usb_source.cpp
    ${NSSFT_CORE_DIR}/h264.cpp
    ${NSSFT_CORE_DIR}/gop_cache.cpp
    ${NSSFT_CORE_DIR}/frame_loss.cpp
    ${NSSFT_CORE_DIR}/log.cpp
    ${NSSFT_CORE_DIR}/i18n.cpp
)

target_compile_options(entry PRIVATE -Wall -Wextra)

target_link_libraries(entry PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_media_codecbase.so
    libnative_media_core.so
    libnative_media_vdec.so
    libohaudio.so
    libnative_window.so
    libnative_vsync.so
    libnative_display_soloist.so
    # libvideo_processing.so 不链接：有的设备没有这个库，video_enhancer.cpp 用到时再 dlopen
)
