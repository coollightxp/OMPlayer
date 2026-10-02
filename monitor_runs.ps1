param(
    [int]$MaxWaitMinutes = 60,
    [int]$PollIntervalSeconds = 30
)

$token = [System.IO.File]::ReadAllText("C:\Users\Administrator\Documents\trae_projects\OMPlayer\.gh_token").Trim()
$headers = @{
    "Authorization" = "token $token"
    "Accept" = "application/vnd.github.v3+json"
    "User-Agent" = "OMPlayer-Monitor"
}

$repo = "coollightxp/OMPlayer"
$releaseRunId = 36872551779
$pushRunId = 36872514870
$startTime = Get-Date

Write-Output "=== Monitoring GitHub Actions for OMPlayer v1.0.98 ==="
Write-Output "Release Run ID: $releaseRunId"
Write-Output "Push Run ID: $pushRunId"
Write-Output "Start time: $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Output ""

$releaseRun = $null
$pushRun = $null

$iteration = 0
while ($true) {
    $iteration++
    $elapsed = (Get-Date) - $startTime
    $elapsedMin = [math]::Round($elapsed.TotalMinutes, 1)
    Write-Output "--- Poll #$iteration (elapsed: ${elapsedMin} min) ---"

    if ($elapsed.TotalMinutes -gt $MaxWaitMinutes) {
        Write-Output "TIMEOUT: Exceeded $MaxWaitMinutes minutes"
        break
    }

    $releaseDone = $false
    $pushDone = $false

    # Check release run
    try {
        $releaseRun = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/runs/$releaseRunId" -Headers $headers -Method Get
        Write-Output "  RELEASE: status=$($releaseRun.status) conclusion=$($releaseRun.conclusion)"
        if ($releaseRun.status -eq "completed") { $releaseDone = $true }
    } catch {
        Write-Output "  RELEASE: Error - $($_.Exception.Message)"
    }

    # Check push run
    try {
        $pushRun = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/runs/$pushRunId" -Headers $headers -Method Get
        Write-Output "  PUSH:    status=$($pushRun.status) conclusion=$($pushRun.conclusion)"
        if ($pushRun.status -eq "completed") { $pushDone = $true }
    } catch {
        Write-Output "  PUSH: Error - $($_.Exception.Message)"
    }

    # Check for failures
    if ($releaseDone -and $releaseRun.conclusion -ne "success") {
        Write-Output ""
        Write-Output "!!! RELEASE RUN FAILED: conclusion=$($releaseRun.conclusion) !!!"
        try {
            $jobs = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/runs/$releaseRunId/jobs" -Headers $headers -Method Get
            foreach ($job in $jobs.jobs) {
                $jobStatus = if ($job.conclusion) { $job.conclusion } else { $job.status }
                Write-Output "  Job: $($job.name) - $jobStatus"
                if ($job.conclusion -ne "success" -and $job.conclusion -ne "skipped") {
                    Write-Output "    FAILED: $($job.name) - conclusion=$($job.conclusion) - $($job.html_url)"
                }
            }
        } catch {}
        if ($pushDone) { break }
        Write-Output "Waiting for PUSH run to finish..."
    }

    if ($pushDone -and $pushRun.conclusion -ne "success") {
        Write-Output ""
        Write-Output "!!! PUSH RUN FAILED: conclusion=$($pushRun.conclusion) !!!"
        try {
            $jobs = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/runs/$pushRunId/jobs" -Headers $headers -Method Get
            foreach ($job in $jobs.jobs) {
                $jobStatus = if ($job.conclusion) { $job.conclusion } else { $job.status }
                Write-Output "  Job: $($job.name) - $jobStatus"
                if ($job.conclusion -ne "success" -and $job.conclusion -ne "skipped") {
                    Write-Output "    FAILED: $($job.name) - conclusion=$($job.conclusion) - $($job.html_url)"
                }
            }
        } catch {}
        if ($releaseDone) { break }
        Write-Output "Waiting for RELEASE run to finish..."
    }

    if ($releaseDone -and $pushDone) {
        Write-Output ""
        Write-Output "=== BOTH RUNS COMPLETED ==="
        break
    }

    Write-Output ""
    Start-Sleep -Seconds $PollIntervalSeconds
}

# Final report
Write-Output ""
Write-Output "========== FINAL REPORT =========="
Write-Output "Time: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Output ""

if ($releaseRun) {
    $rStart = [DateTime]::Parse($releaseRun.created_at)
    $rEnd = if ($releaseRun.updated_at) { [DateTime]::Parse($releaseRun.updated_at) } else { Get-Date }
    $rDuration = $rEnd - $rStart
    Write-Output "RELEASE Run (v1.0.98):"
    Write-Output "  Name: $($releaseRun.name)"
    Write-Output "  Run #: $($releaseRun.run_number)"
    Write-Output "  Status: $($releaseRun.status)"
    Write-Output "  Conclusion: $($releaseRun.conclusion)"
    Write-Output "  Duration: $([math]::Round($rDuration.TotalMinutes, 1)) minutes"
    Write-Output "  URL: $($releaseRun.html_url)"

    # Get job details
    try {
        $jobs = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/runs/$releaseRunId/jobs" -Headers $headers -Method Get
        Write-Output "  Jobs:"
        foreach ($job in $jobs.jobs) {
            $jobConclusion = if ($job.conclusion) { $job.conclusion } else { "running" }
            $jStart = if ($job.started_at) { [DateTime]::Parse($job.started_at) } else { $null }
            $jEnd = if ($job.completed_at) { [DateTime]::Parse($job.completed_at) } else { Get-Date }
            $jDuration = if ($jStart) { [math]::Round(($jEnd - $jStart).TotalMinutes, 1) } else { "?" }
            Write-Output "    - $($job.name): $jobConclusion (${jDuration} min)"
        }
    } catch {}
} else {
    Write-Output "RELEASE Run: NOT FOUND"
}

Write-Output ""

if ($pushRun) {
    $pStart = [DateTime]::Parse($pushRun.created_at)
    $pEnd = if ($pushRun.updated_at) { [DateTime]::Parse($pushRun.updated_at) } else { Get-Date }
    $pDuration = $pEnd - $pStart
    Write-Output "PUSH(main) Run:"
    Write-Output "  Name: $($pushRun.name)"
    Write-Output "  Run #: $($pushRun.run_number)"
    Write-Output "  Status: $($pushRun.status)"
    Write-Output "  Conclusion: $($pushRun.conclusion)"
    Write-Output "  Duration: $([math]::Round($pDuration.TotalMinutes, 1)) minutes"
    Write-Output "  URL: $($pushRun.html_url)"

    try {
        $jobs = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/runs/$pushRunId/jobs" -Headers $headers -Method Get
        Write-Output "  Jobs:"
        foreach ($job in $jobs.jobs) {
            $jobConclusion = if ($job.conclusion) { $job.conclusion } else { "running" }
            $jStart = if ($job.started_at) { [DateTime]::Parse($job.started_at) } else { $null }
            $jEnd = if ($job.completed_at) { [DateTime]::Parse($job.completed_at) } else { Get-Date }
            $jDuration = if ($jStart) { [math]::Round(($jEnd - $jStart).TotalMinutes, 1) } else { "?" }
            Write-Output "    - $($job.name): $jobConclusion (${jDuration} min)"
        }
    } catch {}
} else {
    Write-Output "PUSH(main) Run: NOT FOUND"
}

Write-Output ""
Write-Output "=================================="

# Cleanup temp files
Remove-Item "C:\Users\Administrator\Documents\trae_projects\OMPlayer\get_token.ps1" -ErrorAction SilentlyContinue
Remove-Item "C:\Users\Administrator\Documents\trae_projects\OMPlayer\check_runs.ps1" -ErrorAction SilentlyContinue
Remove-Item "C:\Users\Administrator\Documents\trae_projects\OMPlayer\.gh_token" -ErrorAction SilentlyContinue
