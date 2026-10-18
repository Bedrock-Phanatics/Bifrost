cmake_minimum_required(VERSION 3.20)
project(BifrostChatGuard LANGUAGES CXX)

include("../../cmake/BifrostPlugin.cmake")
add_library(ChatGuard SHARED src/ChatGuard.cpp)
target_compile_features(ChatGuard PRIVATE cxx_std_23)
set_target_properties(ChatGuard PROPERTIES PREFIX "" CXX_VISIBILITY_PRESET hidden
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
bifrost_embed_manifest(ChatGuard plugin.toml)
if(MINGW)
    target_link_options(ChatGuard PRIVATE -static)
endif()
install(TARGETS ChatGuard LIBRARY DESTINATION plugins RUNTIME DESTINATION plugins)
