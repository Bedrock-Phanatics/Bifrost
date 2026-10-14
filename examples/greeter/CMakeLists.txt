cmake_minimum_required(VERSION 3.20)
project(BifrostGreeter LANGUAGES CXX)

include("../../cmake/BifrostPlugin.cmake")
add_library(Greeter SHARED Greeter.cpp)
target_compile_features(Greeter PRIVATE cxx_std_23)
set_target_properties(Greeter PROPERTIES PREFIX "" CXX_VISIBILITY_PRESET hidden
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
bifrost_embed_manifest(Greeter plugin.toml)
if(MINGW)
    target_link_options(Greeter PRIVATE -static)
endif()
install(TARGETS Greeter LIBRARY DESTINATION plugins RUNTIME DESTINATION plugins)
