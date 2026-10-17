# Godot 本地 Qwen Demo

输入问题 → 点击发送 → 一次性显示完整回复；支持取消。独立单轮问答，不联网调用 API。

## 环境

- Godot **4.7.2**。
- 原生扩展：Python **3.12+**、CMake **3.24+**、C++17 编译器。
  - Windows / Linux 的 x86_64 版本要求支持 AVX2 的处理器。
  - Windows：Visual Studio 2022 的「使用 C++ 的桌面开发」，在开发者终端执行。
  - Linux：GCC 或 Clang。
  - iOS：**macOS + 完整 Xcode**；目标 iOS **16.4+**。
- 当前 Demo 使用 **CPU 推理**，没有启用 Metal。

## 放入模型

手动下载 [Unsloth Qwen3.5-0.8B-Q4_0.gguf](https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/blob/main/Qwen3.5-0.8B-Q4_0.gguf)，放到：

```text
models/Qwen3.5-0.8B-Q4_0.gguf
```

- GGUF 不纳入 Git；项目不提供模型下载或校验脚本。
- 文件名必须与上述路径完全一致；下载文件若带有 `_un` 等后缀，先另存为 `Qwen3.5-0.8B-Q4_0.gguf`，否则导出预设不会打包该模型。
- 只做文字推理，无需 mmproj。
- 导出包需包含模型。首次启动复制到应用沙盒，再由原生代码加载；需预留模型副本空间。
- 替换已导出应用中的模型后，清除旧应用数据或重装，避免继续使用沙盒旧副本。

## 电脑运行

在项目根目录执行：

```sh
python scripts/fetch_dependencies.py
python scripts/build.py
```

- 第一条只准备固定版本的 **C++ 源码依赖**，不下载模型。
- 然后用 Godot 打开 `project.godot`，按 F6/F5 运行。
- 等待「模型已就绪」，输入问题并发送。
- 生成在工作线程进行，界面不等待同步推理；取消后可再次提问。

## iOS 打包

在 Mac 的项目根目录执行：

```sh
python3 scripts/fetch_dependencies.py
python3 scripts/build.py
python3 scripts/build.py --ios
```

- 生成 `bin/libqwen_runner.ios.xcframework`。
- 安装与编辑器版本一致的 Godot 导出模板。
- Godot → 项目 → 导出 → iOS：填入自己的 Team ID、Bundle ID；导出预设已包含上述模型路径。
- 导出 Xcode 工程，用 Xcode 配置签名，连接 iPhone 构建运行。
- Linux / Windows 不能完成这个 Apple 构建和签名步骤。

### iPhone 停在启动画面

- 若 Xcode 控制台出现 `symbol not found in flat namespace '_qwen_library_init'`，检查 `bin/libqwen_runner.ios.xcframework` 是否已生成，并在编译后重新从 Godot 导出 Xcode 工程。
- 删除 Xcode `Other Linker Flags` 中的 `-Wl,-U,_qwen_library_init`；这个参数允许缺少原生入口的程序通过链接，随后会在手机启动时崩溃。
- 确认 Xcode Scheme 的 Build / Run 引用当前工程中的 `QwenDemo` target；本次也修正了导出 Scheme 中不匹配的 target 引用。
- 正常启动后，控制台会输出 `[QwenDemo] Main scene ready`，随后出现 `Model state: loading` 和 `Model state: ready`。首次启动还需把约 484 MiB 模型复制到沙盒，界面会显示进度。

## 范围

- 单次输入、单次回复；不保存对话，不执行模型生成的指令。
- 上下文 1024 tokens，最多生成 192 tokens；过长输入会提示缩短。
- 模型缺失、加载失败、原生扩展缺失均显示错误。
- 切入后台取消推理；退出前安全等待原生工作线程结束。
- 模型文件大小不等于运行内存。iOS 构建与真机性能需要在 Mac / iPhone 验证。

## 依赖

- [llama.cpp](https://github.com/ggml-org/llama.cpp/tree/d81235049384534c167caea52b85a694f6103d14)：MIT；固定提交 `d81235049384534c167caea52b85a694f6103d14`。
- [godot-cpp](https://github.com/godotengine/godot-cpp/tree/e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77)：MIT；4.5 兼容接口，固定提交 `e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77`。
- [Qwen3.5-0.8B](https://huggingface.co/Qwen/Qwen3.5-0.8B)：Apache 2.0；使用用户指定的 Unsloth 量化文件。分发模型时保留上游许可与声明。
- 源码依赖保留各自许可；分发编译二进制时一并提供相关许可。

## 验证状态

- Linux：原生编译、真实 GGUF 推理、Godot 非流式完整回复通过。
- 自动测试：24 项 UI、21 项 Godot 原生联调、UTF-8/模板、20 次取消及加载/退出生命周期通过。
- macOS（2026-10-17）：原生编译、UTF-8/模板测试、26 项 UI 检查、21 项原生联调通过。
- iOS（2026-10-17）：真机 arm64、模拟器 arm64 / x86_64 原生库编译及 Xcode 签名构建通过；iPhone XS Max（iOS 18.7.10）已安装，用户确认启动后显示「模型已就绪」。真机问答由用户继续验证。
- Windows：提供构建配置，尚未实际编译。
