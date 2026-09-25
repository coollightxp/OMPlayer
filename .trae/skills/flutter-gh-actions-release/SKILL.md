---
name: flutter-gh-actions-release
description: Set up or fix GitHub Actions multi-platform builds (Android APK, Web, Windows, macOS) for a Flutter project and attach artifacts to a GitHub Release. Use when the user wants CI/CD builds, Release downloads, or hits build failures such as AAR metadata, CMake generator, or plugin API errors. Do not use for local-only builds or non-Flutter projects.
---

# Flutter GitHub Actions 多平台构建与 Release 发布

目标：push 代码或发布 Release 时，GitHub Actions 自动构建 Android/Web/Windows/macOS 四平台成品并上传到 Release 供下载。

## 标准工作流

1. 确认代码已推送到 GitHub（用户不熟 Git 时直接用命令行 `C:\Program Files\Git\bin\git.exe` 推送，比 GitHub Desktop 更稳；国内网络可设 `git config http.postBuffer 524288000`）。
2. 编写 `.github/workflows/build.yml`（模板见 `references/workflow-template.yml`），要点：
   - 触发器：`push` + `release: types: [published]` + `workflow_dispatch`
   - `permissions: contents: write`（上传 Release 必需）
   - 四个独立 job，均先 `flutter create . --platforms=<平台> --project-name <包名>` 再 `flutter pub get` 再构建（仓库通常不提交平台目录）
   - 用 `softprops/action-gh-release@v2` 上传，加 `if: github.event_name == 'release'`
   - Web/Windows/macOS 需先 zip 再上传；Android 用 `--split-per-abi` 直接传多个 APK
3. 通过 GitHub API 创建 Release 触发构建：
   `curl -X POST -H "Authorization: token <PAT>" https://api.github.com/repos/<owner>/<repo>/releases -d '{"tag_name":"v1.0.0","name":"v1.0.0"}'`
4. 拉取失败日志定位错误：
   `curl -H "Authorization: token <PAT>" "https://api.github.com/repos/<owner>/<repo>/actions/runs?per_page=5"` 拿 run id → `.../runs/<id>/jobs` 拿 job id → `.../jobs/<id>/logs` 看日志。
5. 修复后删除旧 Release 和 tag 重建（Release 触发器只在 published 时触发一次）：
   `curl -X DELETE .../releases/<id>` + `curl -X DELETE .../git/refs/tags/<tag>`。

## 排错决策（按出现频率排序）

详细错误目录见 `references/error-catalog.md`，核心原则：

1. **Flutter 版本是第一嫌疑**。GitHub runner 的 Visual Studio / JDK / Gradle 都很新，Flutter 过旧会连环报错。Windows 报 `Visual Studio 16 2019 not found` 或 Android 报 `unknown property 'flutter'` / `compileSdkVersion not specified`，直接升级 workflow 里的 `flutter-version` 到最新 stable，不要试图改 CMakeLists.txt 或设 `CMAKE_GENERATOR`——生成器由 Flutter 工具内部指定，外部干预无效。
2. **AAR metadata 报 compileSdk 不足**：某个插件（或其传递依赖如 flutter_plugin_android_lifecycle）用更高 compileSdk 编译，升级该插件到大版本。
3. **插件大版本升级必查 API 变更**（pub.dev 看 changelog）：
   - `volume_controller` 3.x：`VolumeController.instance.getVolume()/setVolume(v)` 单例，无 maxVolume
   - `screen_brightness` 2.x：`ScreenBrightness.instance.application` 读取、`setApplicationScreenBrightness(v)` 设置
   - `file_picker` 12+/13.x：`FilePicker.pickFile(...)` 返回 `PlatformFile?`，无 `FilePicker.platform`/`FilePickerResult`
   - `screenshot` 2.x 与新 Flutter 的 `ViewConfiguration.size` 不兼容：改用 git master 分支
4. **依赖版本冲突**（如 win32 版本区间不交集）：先查该依赖是否真的被 import，未使用就直接删掉，比找兼容版本快。
5. **Dart 编译错误在四个 job 里会各报一次**，修一处即可全过；常见为缺 import、`StatelessWidget` 里用了不存在的 `context`。

## 迭代节奏

创建 Release → 等 Actions 跑完 → 拉日志 → 一次修掉所有平台共有的编译错误 → 删 Release+tag → 重建。Android 环境最敏感，优先修 Android；Dart 语法错误全平台共享，先修。
