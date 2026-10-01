param(
  [string]$Session = 'web-channel-stuck',
  [int]$Port = 7777,
  [string]$OutDir = '.dbg',
  [int]$Idle = 1800
)
$ErrorActionPreference = 'Stop'
$out = [System.IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force -Path $out | Out-Null
$logFile = Join-Path $out "trae-debug-log-$Session.ndjson"
if (Test-Path $logFile) { Clear-Content $logFile } else { New-Item -ItemType File -Force -Path $logFile | Out-Null }

$listener = $null
$actualPort = $Port
for ($i = 0; $i -lt 10; $i++) {
  $l = New-Object System.Net.HttpListener
  $l.Prefixes.Add("http://127.0.0.1:$($Port + $i)/")
  try { $l.Start(); $listener = $l; $actualPort = $Port + $i; break } catch { try { $l.Close() } catch {} }
}
if (-not $listener) { Write-Output 'ERROR: no available port'; exit 1 }

$envFile = Join-Path $out "$Session.env"
Set-Content -Path $envFile -Value ("DEBUG_SERVER_URL=http://127.0.0.1:$actualPort/event`nDEBUG_SESSION_ID=$Session") -Encoding ASCII

Write-Output '@@DEBUG_SERVER_INFO'
Write-Output (@{ api_url = "http://127.0.0.1:$actualPort/event"; session_id = $Session; log_dir = $out; log_file = $logFile; env_file = $envFile } | ConvertTo-Json -Compress)
Write-Output '@@END_DEBUG_SERVER_INFO'

function Send-Text($res, [int]$code, [string]$text) {
  $res.StatusCode = $code
  $buf = [System.Text.Encoding]::UTF8.GetBytes($text)
  $res.OutputStream.Write($buf, 0, $buf.Length)
}

$lastActivity = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
while ($listener.IsListening) {
  $task = $listener.GetContextAsync()
  $stopped = $false
  while (-not $task.Wait(500)) {
    if ($Idle -gt 0 -and ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $lastActivity) -gt ($Idle * 1000)) {
      try { $listener.Stop() } catch {}
      $stopped = $true
      break
    }
  }
  if ($stopped -or -not $listener.IsListening) { break }
  if (-not $task.IsCompleted) { break }
  try { $ctx = $task.Result } catch { continue }
  $lastActivity = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $req = $ctx.Request
  $res = $ctx.Response
  try {
    $res.Headers.Add('Access-Control-Allow-Origin', '*')
    $res.Headers.Add('Access-Control-Allow-Methods', 'POST, GET, DELETE, OPTIONS')
    $res.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')
    $path = $req.Url.AbsolutePath
    if ($req.HttpMethod -eq 'OPTIONS') {
      $res.StatusCode = 204
    } elseif ($path -eq '/event' -and $req.HttpMethod -eq 'POST') {
      $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
      $body = $reader.ReadToEnd()
      $reader.Close()
      try {
        $evt = $body | ConvertFrom-Json
        if (-not $evt.PSObject.Properties['ts']) {
          $evt | Add-Member -NotePropertyName ts -NotePropertyValue ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        }
        $line = $evt | ConvertTo-Json -Compress -Depth 10
        [System.IO.File]::AppendAllText($logFile, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
        Send-Text $res 200 'ok'
      } catch {
        Send-Text $res 400 'bad json'
      }
    } elseif ($path -eq '/health') {
      Send-Text $res 200 (@{ status = 'ok'; session = $Session } | ConvertTo-Json -Compress)
    } elseif ($path -eq '/logs' -and $req.HttpMethod -eq 'GET') {
      $content = ''
      if (Test-Path $logFile) { $content = [System.IO.File]::ReadAllText($logFile) }
      Send-Text $res 200 $content
    } elseif ($path -eq '/logs' -and $req.HttpMethod -eq 'DELETE') {
      Clear-Content $logFile
      Send-Text $res 200 'cleared'
    } else {
      Send-Text $res 404 'not found'
    }
  } catch {
    try { Send-Text $res 500 'error' } catch {}
  } finally {
    try { $res.OutputStream.Close() } catch {}
  }
}
try { $listener.Close() } catch {}
Write-Output 'server stopped'
