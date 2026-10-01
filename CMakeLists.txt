cmake_minimum_required(VERSION 3.20)
project(toner_serial_signature VERSION 0.1.0 LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

find_package(OpenSSL REQUIRED COMPONENTS Crypto)

add_library(toner_record STATIC record.c)
target_include_directories(toner_record PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")

add_executable(keygen keygen.c)
add_executable(sign sign.c)
add_executable(verify verify.c)
add_executable(record_test record_test.c)

target_link_libraries(keygen PRIVATE OpenSSL::Crypto)
target_link_libraries(sign PRIVATE toner_record OpenSSL::Crypto)
target_link_libraries(verify PRIVATE toner_record OpenSSL::Crypto)
target_link_libraries(record_test PRIVATE toner_record OpenSSL::Crypto)

# Static OpenSSL on MSVC may need its BIO/CRT compatibility glue. Link it
# privately and only once per executable, as recommended by FindOpenSSL.
if(MSVC AND TARGET OpenSSL::applink)
    foreach(target IN ITEMS keygen sign verify record_test)
        target_link_libraries(${target} PRIVATE OpenSSL::applink)
    endforeach()
endif()

foreach(target IN ITEMS toner_record keygen sign verify record_test)
    if(MSVC)
        target_compile_options(${target} PRIVATE /W4 /WX /wd4996 /utf-8)
    elseif(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
        target_compile_options(${target} PRIVATE
            -Wall -Wextra -Werror -Wno-deprecated-declarations)
    endif()
endforeach()
