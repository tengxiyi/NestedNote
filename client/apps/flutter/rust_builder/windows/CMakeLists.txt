# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
# 注意：这里的 `nested_app`（连字符）对应 Rust crate 名，不是 Dart 包名
# （Dart 包名是 `nested_app`，见 pubspec.yaml）。Cargokit 用 project 名去
# `cargo build -p <名字>`，因此必须与 Cargo.toml 的 package 名一致。
set(PROJECT_NAME "nested_app")
project(${PROJECT_NAME} LANGUAGES CXX)

include("../cargokit/cmake/cargokit.cmake")
apply_cargokit(${PROJECT_NAME} ../../../../../../../rust nested_app "")

# 需要随应用一起打包的动态库。
#
# 变量命名是个踩过的坑，**不要"顺手改成 ${PROJECT_NAME}"**：
#   上层 windows/flutter/generated_plugins.cmake 通过
#       ${${ffi_plugin}_bundled_libraries}   →   nested_app_bundled_libraries
#   收集要拷进应用目录的库，其中 `ffi_plugin` 是 **Dart 包名** `nested_app`；
#   而本文件的 PROJECT_NAME 是 **crate 名** `nested_app`。两者不一致，
#   若写成 `${PROJECT_NAME}_bundled_libraries`，上层读到的是未定义变量（空），
#   结果是：dll 编译成功却**没有被拷进应用目录**，运行时才报"找不到库"。
set(nested_app_bundled_libraries
  "${nested_app_cargokit_lib}"
  PARENT_SCOPE
)
