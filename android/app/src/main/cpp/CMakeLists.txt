cmake_minimum_required(VERSION 3.18.1)
project(cosmiqg729 C)

# bcg729 (BelledonneCommunications, GPLv3) is NOT bundled in the public repo.
# If it has been fetched into ./bcg729 (see README), build the real G.729 codec;
# otherwise build a stub so the app still loads (G.729 just isn't offered).
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/bcg729/include/bcg729/encoder.h")
    file(GLOB BCG729_SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/bcg729/src/*.c)
    add_library(cosmiqg729 SHARED g729_jni.c ${BCG729_SOURCES})
    target_include_directories(cosmiqg729 PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/bcg729/include
        ${CMAKE_CURRENT_SOURCE_DIR}/bcg729/src)
    message(STATUS "Cosmiq: building real G.729 codec from bcg729")
else()
    add_library(cosmiqg729 SHARED g729_stub.c)
    message(STATUS "Cosmiq: bcg729 not found — building G.729 stub (codec disabled)")
endif()

find_library(log-lib log)
target_link_libraries(cosmiqg729 ${log-lib})
