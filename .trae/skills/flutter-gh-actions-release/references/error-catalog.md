# 构建错误目录（OMPlayer 实战记录）

## Windows 平台

### CMake Error: Generator Visual Studio 16 2019 could not find any instance of Visual Studio
- **根因**：Flutter 3.24.0 硬编码查找 VS 2019，GitHub `windows-latest` runner 装的是 VS 2022。
- **修复**：升级 workflow 中 `flutter-version` 到 3.44.8（或当前 stable）。
- **无效尝试**（不要再试）：改 `windows/CMakeLists.txt`、设 `CMAKE_GENERATOR` 环境变量、删 build 目录——生成器由 Flutter 工具内部决定，外部无法覆盖。

## Android 平台

### package_info_plus: compileSdkVersion is not specified / unknown property 'flutter'
- **根因**：Flutter 3.24 旧版 Gradle 配置与新版插件不兼容。
- **修复**：升级 Flutter 到 3.44.8。

### AAR metadata: dependency requires compileSdk >= 36
- **根因**：插件（如 file_picker 8.x 传递依赖 flutter_plugin_android_lifecycle）用高 compileSdk 编译，项目默认太低。Flutter 3.44 默认 compileSdk=36。
- **修复**：升级 Flutter + 升级该插件到近期大版本（如 file_picker → 13.1.0）。

### screen_brightness_android AAR metadata 多个 issue
- **根因**：screen_brightness 1.x 的 Android 实现太旧，不满足现代 AndroidX 要求。
- **修复**：升级到 2.1.11，同时改 API（`ScreenBrightness.instance.application` / `setApplicationScreenBrightness`）。

## 依赖冲突

### win32 version solving failed（如 file_picker 要 ^6.3.0，device_info_plus 10.x 要 <6.0.0）
- **修复**：先全仓库 grep 确认哪个包真的被 import。未使用的直接删（OMPlayer 中 device_info_plus 未使用，删除即解决）。

## Dart 编译错误（全平台共享）

| 报错 | 修复 |
|---|---|
| `VideoPlayer isn't defined` | 文件顶部补 `import 'package:video_player/video_player.dart';` |
| `Undefined name 'context'` 在 StatelessWidget 的静态/helper 方法 | `SliderTheme.of(context).copyWith(...)` 改为直接构造 `SliderThemeData(...)` |
| screenshot: `No named parameter 'size'` (ViewConfiguration) | pubspec 改 git 源：`url: https://github.com/SachinGanesh/screenshot.git, ref: master` |
| file_picker: `FilePicker.platform` / `FilePickerResult` 未定义 | 12+ 重构后：`final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: [...]);` 返回 `PlatformFile?`，取 `file?.path` |
| volume_controller: `maxVolume` 不存在 | 3.x 直接用 0.0~1.0：`VolumeController.instance.setVolume(_volume)` |

## GitHub 操作速查（PowerShell + curl，PAT 需 repo 权限）

```powershell
# 创建 Release（触发构建）
curl.exe -X POST -H "Authorization: token $env:PAT" -H "Content-Type: application/json" `
  https://api.github.com/repos/<owner>/<repo>/releases `
  -d '{"tag_name":"v1.0.0","target_commitish":"main","name":"v1.0.0"}'

# 查最近 workflow runs
curl.exe -H "Authorization: token $env:PAT" "https://api.github.com/repos/<owner>/<repo>/actions/runs?per_page=5"

# 查某次 run 的 jobs
curl.exe -H "Authorization: token $env:PAT" "https://api.github.com/repos/<owner>/<repo>/actions/runs/<run_id>/jobs"

# 看失败 job 日志
curl.exe -H "Authorization: token $env:PAT" "https://api.github.com/repos/<owner>/<repo>/actions/jobs/<job_id>/logs"

# 删除 Release 和 tag（重建前）
curl.exe -X DELETE -H "Authorization: token $env:PAT" "https://api.github.com/repos/<owner>/<repo>/releases/<release_id>"
curl.exe -X DELETE -H "Authorization: token $env:PAT" "https://api.github.com/repos/<owner>/<repo>/git/refs/tags/v1.0.0"
```

注意：PowerShell 里用 `curl.exe` 而不是 `curl`（后者是 Invoke-WebRequest 别名，参数不兼容）。
