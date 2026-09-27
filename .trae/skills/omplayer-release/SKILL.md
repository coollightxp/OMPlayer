---
name: omplayer-release
description: OMPlayer 发版流程，bump pubspec 版本号、推送 main、打 tag、创建中文 Release、后台监控 GitHub Actions 构建。用户要求发版/发布新版本/出包时使用。不要用于普通提交或不发 Release 的改动。
---

# OMPlayer 发版流程

仓库 coollightxp/OMPlayer（公共库），推送 tag 触发 GitHub Actions 出包（Flutter 3.44.8，所有 job 统一版本）。本机无 Flutter SDK，静态检查只能靠 GetDiagnostics（无输出=无错误）。

## 前置

1. 改动先完成并用 GetDiagnostics 检查涉及的 dart 文件；跨文件新增 getter 时人工核对 UI 引用（缺 getter 只在 Windows job 暴露）。
2. 版本号：`pubspec.yaml` 的 `version: X.Y.Z+B`。语义版本递增；build 号 `B` 每次发版 +1（如 `1.0.33+33` → `1.0.34+34`）。tag 为 `vX.Y.Z`。
3. Git 一律用完整路径：`& "C:\Program Files\Git\bin\git.exe"`（cwd 已是项目根，不要 cd）。

## 发版步骤

1. 写 Release 正文到临时文件（JSON，中文）：`C:\Users\Administrator\AppData\Local\Temp\omplayer_release_body.json`，结构 `{"tag_name":"vX.Y.Z","name":"...","body":"...","draft":false,"prerelease":false}`。
2. 提交、推送、打 tag、推送 tag（一条链式命令）：

```powershell
& "C:\Program Files\Git\bin\git.exe" add -A
& "C:\Program Files\Git\bin\git.exe" commit -m "vX.Y.Z: 简述"
& "C:\Program Files\Git\bin\git.exe" push origin main
& "C:\Program Files\Git\bin\git.exe" tag -a vX.Y.Z -m "vX.Y.Z"
& "C:\Program Files\Git\bin\git.exe" push origin vX.Y.Z
```

3. 用字节方式 POST 建 Release（PowerShell 5 内嵌中文字符串会乱码/截断，必须先写 JSON 文件再 `[System.IO.File]::ReadAllBytes`）：

```powershell
$cred = "protocol=https`nhost=github.com`n" | & "C:\Program Files\Git\bin\git.exe" credential fill 2>$null
$token = ($cred | Where-Object {$_ -like 'password=*'}) -replace 'password=',''
$bytes = [System.IO.File]::ReadAllBytes("$env:TEMP\omplayer_release_body.json")
$rel = Invoke-RestMethod -Uri "https://api.github.com/repos/coollightxp/OMPlayer/releases" -Method Post -Headers @{Authorization="token $token"; Accept="application/vnd.github+json"} -ContentType "application/json; charset=utf-8" -Body $bytes
"RELEASE id=$($rel.id) url=$($rel.html_url)"
```

4. 删除临时 JSON 文件（用 DeleteFile）。
5. 后台监控构建（run_in_background），轮询间隔 30s，**必须加 `created_at` 时间过滤**（否则匹配旧 run 误判），seen 去重；同时关注 `release(vX.Y.Z)` 和 `push(main)` 两个 run，全部 conclusion=success 才算完成。中途 502 是 GitHub API 瞬时抖动，下轮重试即可。
6. 完成后向用户汇报两个 run 结论与 Release 链接。产物（Windows/Linux/Web zip + 3 个 split-per-abi APK）由 workflow 自动附加，无需手动上传。

## 注意

- stderr 里的 PSSecurityException（禁止运行脚本）是无害噪音，忽略。
- 只在用户明确要求发版时提交和打 tag；不要 amend、不要 force push、不要移动已推送的 tag（修复失败需要重发时递增新版本号）。
- 若 release run 失败需重跑同一提交，用 `POST /actions/runs/{id}/rerun`，不要重新 tag。
