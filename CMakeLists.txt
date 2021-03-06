# Copyright 2017 The NXT Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

cmake_minimum_required(VERSION 2.8)
project(nxt C CXX)

function(SetCXX14 Target)
    if(MSVC)
        set_property(TARGET ${Target} APPEND PROPERTY COMPILE_OPTIONS "/std:c++14")
    else()
        set_property(TARGET ${Target} APPEND PROPERTY COMPILE_OPTIONS "-std=c++14")
    endif()
endfunction()
function(SetPIC Target)
    if(MSVC)
    else()
        set_property(TARGET ${Target} APPEND PROPERTY COMPILE_OPTIONS "-fPIC")
    endif()
endfunction()

add_subdirectory(third_party)
add_subdirectory(generator)

set(INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/src/include)

Generate(
    LIB_NAME nxt
    LIB_TYPE SHARED
    PRINT_NAME libNXT
    COMMAND_LINE_ARGS
        ${GENERATOR_COMMON_ARGS}
        -T nxt
)
target_include_directories(nxt PUBLIC ${GENERATED_DIR})

Generate(
    LIB_NAME nxtcpp
    LIB_TYPE SHARED
    PRINT_NAME libNXT++
    COMMAND_LINE_ARGS
        ${GENERATOR_COMMON_ARGS}
        -T nxtcpp
)
target_include_directories(nxtcpp PUBLIC ${GENERATED_DIR} PUBLIC ${INCLUDE_DIR})
target_link_libraries(nxtcpp nxt)
SetCXX14(nxtcpp)

Generate(
    LIB_NAME mock_nxt
    LIB_TYPE SHARED
    PRINT_NAME libMockNXT
    COMMAND_LINE_ARGS
        ${GENERATOR_COMMON_ARGS}
        -T mock_nxt
)
target_include_directories(mock_nxt PUBLIC ${GENERATED_DIR})
target_link_libraries(mock_nxt nxt gtest)
SetCXX14(mock_nxt)

add_subdirectory(src/backend)
add_subdirectory(src/wire)
add_subdirectory(src/tests)

add_subdirectory(examples)
