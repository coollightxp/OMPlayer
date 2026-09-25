# OMPlayer

跨平台 Flutter 直播流媒体播放器，支持播放列表管理、EPG 节目单、节目预约、录制与截图。

## 功能特性

- 📺 **直播播放**：支持 HLS/DASH 等直播流播放
- 📋 **播放列表管理**：支持 M3U / TXT 格式，URL 或本地文件导入
- 📅 **EPG 节目单**：XMLTV 格式解析，支持多 EPG 源切换
- ⏰ **节目预约**：到时间自动切换到对应频道
- 🎬 **录制与截图**：桌面端支持 ffmpeg 录制流、画面截图
- 🎚️ **手势控制**：左侧上下滑调亮度，右侧上下滑调音量
- 🗂️ **两级抽屉**：左侧频道分类抽屉，右侧 EPG 节目面板

## 平台支持

| 平台 | 支持状态 |
|------|---------|
| Android | ✅ |
| iOS | ✅ |
| Web | ✅ |
| Windows | ✅（含录制/截图） |
| macOS | ✅（含录制/截图） |
| Linux | ⚠️（理论支持，需自行构建） |

> 桌面端录制功能需要系统已安装 `ffmpeg` 并加入 PATH。

## 自动构建

推送代码到 `main` 分支后，GitHub Actions 会自动构建以下产物：

- Android APK（arm64-v8a / armeabi-v7a / x86_64）
- Web 静态站点
- Windows 桌面应用（zip）
- macOS 桌面应用（zip）

构建产物可在仓库的 **Actions** 页面下载，或在发布 **Release** 时自动附加到发行版。

## 本地构建

```bash
flutter pub get
flutter run
```

### 桌面端

```bash
flutter config --enable-windows-desktop
flutter build windows --release
```

## 使用说明

1. 点击中间区域调出底部控制栏，点击设置按钮
2. 在「播放列表」标签页添加 M3U/TXT 源（URL 或本地文件）
3. 在「EPG」标签页添加 XMLTV 节目单地址
4. 从左侧抽屉选择频道开始播放
5. 右侧面板查看节目单并预约节目
