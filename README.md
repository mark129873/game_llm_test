# Godot 本地双模型评测

离线、单轮、CPU 推理；默认 Qwen，可切换 Bonsai。完整回复一次显示，支持取消。切换先卸载旧模型，不同时驻留两套权重。

## 环境与运行

- Godot **4.7.2**，Python **3.9+**，CMake **3.24+**，C++17 编译器。
- Windows：Visual Studio 2022 C++ 开发者终端；Linux：GCC/Clang；macOS：Xcode 工具链。
- x86_64 构建要求 AVX2。只启用 CPU，禁用 Metal/CUDA/Vulkan/Accelerate。

手动把以下 GGUF 放进 `models/`，无需 mmproj：

```text
models/Qwen3.5-0.8B-Q4_0.gguf
models/Ternary-Bonsai-2-2B-Q2_0.gguf
```

Qwen 也支持带 `_un` 的文件名；导出包含 `Qwen3.5-0.8B-Q4_0*.gguf`。请只保留一份 Qwen，避免别名选择歧义与重复打包。模型不进 Git；所有脚本均不下载 GGUF。

```sh
python3 scripts/fetch_dependencies.py
python3 scripts/build.py
```

第一条仅下载固定版本 C++ 源码并验证 SHA256；第二条构建原生扩展、运行 CTest。 若已有旧版 `vendor/llama.cpp`，先将该目录移到项目外备份，再重新执行依赖脚本；脚本不会覆盖已有源码。Windows 可将 `python3` 换成 `python`。用 Godot 打开 `project.godot`，F6/F5 运行，等待所选模型就绪后发送。

模型按块复制到各自的应用沙盒缓存，再交给原生代码加载；预留模型副本空间。导出后更换模型时清除应用数据或重装，防止使用旧缓存。

## 计时口径

- 两模型统一：最多 4 个 CPU 线程、上下文 1024、输出上限 192 tokens；top-k 20、top-p 0.8、temperature 0.7、seed 42；非思考、无历史对话。
- decode 时间只累加成功的单 token `llama_decode` 与紧随其后的 `llama_synchronize`；排除复制、加载、prefill、采样与 UI。
- 速度为 decode token 数 / decode 秒数；首个输出由 prefill 产生，所以 decode token 数与输出 token 数可以不同，达到输出上限时通常少 1。
- 取消或错误不显示有效成绩。相同设置不保证跨模型答案或速度一致；公平比较还需同设备、同提示与相近温度/后台负载。

## iOS 16.4+

必须在 **Mac + 完整 Xcode** 上运行：

```sh
python3 scripts/fetch_dependencies.py
python3 scripts/build.py
python3 scripts/build.py --ios
```

脚本逐架构检查静态库中的 `qwen_library_init` 入口，生成 `bin/libqwen_runner.ios.xcframework`（arm64 真机、arm64/x86_64 模拟器）。安装匹配 Godot 4.7.2 的导出模板，在 iOS 预设填写 Team ID、Bundle ID，导出 `build/ios/QwenDemo.xcodeproj`，再用 Xcode 签名并连接 iPhone 运行。预设打包两个模型与 Qwen 别名。构建脚本不负责 Godot 导出、签名或真机测试。

### iPhone 停在启动画面

- 若 Xcode 控制台出现 `symbol not found in flat namespace '_qwen_library_init'`，检查 `bin/libqwen_runner.ios.xcframework` 是否已生成，并在编译后重新从 Godot 导出 Xcode 工程。
- 删除 Xcode `Other Linker Flags` 中的 `-Wl,-U,_qwen_library_init`；这个参数允许缺少原生入口的程序通过链接，随后会在手机启动时崩溃。
- 确认 Xcode Scheme 的 Build / Run 引用当前工程中的 `QwenDemo` target；此前装机修复已修正导出 Scheme 中不匹配的 target 引用。
- 正常启动后，控制台会输出 `[QwenDemo] Main scene ready`，随后出现 `Model state: loading` 和 `Model state: ready`。所选模型首次使用还需分块复制到独立沙盒缓存，界面会显示进度。


切入后台取消推理，退出等待工作线程结束。模型大小不等于峰值内存；Bonsai 真机内存与性能仍需实测。

## 固定依赖与兼容性

- [llama.cpp a9d27ac](https://github.com/ggml-org/llama.cpp/commit/a9d27ac693ff0a1d3cba449c912c2b891904a4c7)，MIT。官方提交加入 Prism Bonsai 2 27B 支持；源码包含 Q2_0、`prism.hadamard` v1/v2 与 Qwen3/Qwen3.5 图路径检查。这是兼容性依据，不能代替对所选 2-2B GGUF 的实际加载验证。
- llama 源码包 SHA256：`8ea0196592a372457ab88c0f23497e9030b4942524100956261d35f18fcd2f64`。
- [godot-cpp e83fd09](https://github.com/godotengine/godot-cpp/tree/e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77)，MIT，4.5 兼容接口。
- [Bonsai 官方模型卡](https://huggingface.co/prism-ml/Ternary-Bonsai-2-2B-gguf)说明它基于 Qwen3.5-2B，保持架构并使用分块 Hadamard；目标 GGUF 的实际加载仍待验证。
- Qwen 使用用户指定的 Unsloth 量化版。分发模型前核对各自上游许可证；分发原生二进制保留依赖许可与声明。

## 验证边界

以下历史记录来自远端实际装机修复，保留作为旧版单模型的验证结果。本次升级 llama.cpp 与双模型后，云端未提供两份目标 GGUF，尚未验证真实推理、速度和峰值内存；也尚未重新执行 macOS/iOS 构建或 iPhone 真机测试。旧版装机成功不代表本次双模型已通过。

### 远端旧版单模型记录（9c41dda）

- Linux：原生编译、真实 GGUF 推理、Godot 非流式完整回复通过。
- 自动测试：24 项 UI、21 项 Godot 原生联调、UTF-8/模板、20 次取消及加载/退出生命周期通过。
- macOS（2026-10-17）：原生编译、UTF-8/模板测试、26 项 UI 检查、21 项原生联调通过。
- iOS（2026-10-17）：真机 arm64、模拟器 arm64 / x86_64 原生库编译及 Xcode 签名构建通过；iPhone XS Max（iOS 18.7.10）已安装，用户确认启动后显示「模型已就绪」。真机问答由用户继续验证。
- Windows：提供构建配置，尚未实际编译。

### 本次双模型升级

无模型静态测试：`python3 -m unittest discover -s tests -p 'test_*.py'`。原生与 Godot 测试以本次实际运行结果为准，不沿用旧版测试计数。

拿到真实模型后，在 Linux/macOS 分别运行（Windows 使用对应 `.exe` 路径）：

```sh
build/linux/qwen_smoke models/Qwen3.5-0.8B-Q4_0.gguf
build/linux/qwen_smoke models/Ternary-Bonsai-2-2B-Q2_0.gguf
```

macOS 将 `build/linux` 换为 `build/darwin`。测试默认提问 2+2，忽略空白后必须回答 `4` 或 `4.`，同时检查无思考/控制标记、正且一致的 decode 指标、重复请求拒绝与卸载；不是仅检查非空输出。自定义问题必须再传入预期答案子串：`qwen_smoke 模型路径 "问题" "预期子串"`。没有真实 GGUF 时这些语义测试不能算通过。

本次 Linux 检查：原生完整构建、CTest 2/2、Python 8/8、Godot 4.7.2 UI 54/54（已加载扩展）、无模型原生桥 9/9、编辑器导入与主场景无模型启动通过。无模型测试可运行：

```sh
godot --headless --path . --script tests/test_ui.gd
godot --headless --path . --script tests/native_integration.gd -- --no-model
```

请确认 `godot --version` 是 4.7.2；受限环境需将 HOME、XDG_DATA_HOME、XDG_CACHE_HOME 指向可写目录。以上不包含真实模型语义测试、模型切换内存峰值或 iOS 性能结论。
