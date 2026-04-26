cmake_minimum_required(VERSION 3.16)

project(warehouse_api LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(Drogon CONFIG REQUIRED)

add_executable(warehouse-api
  src/main.cpp
)

target_link_libraries(warehouse-api PRIVATE Drogon::Drogon)
