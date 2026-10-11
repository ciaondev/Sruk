# Sruk vs IrfanView 자체 벤치마크 (재현용)
# 두 프로그램을 같은 사진으로 번갈아 실행해 창 표시 시간, 사진 표시 완료(대리 지표), 메모리를 잰다.
# 회차별 원본 값은 CSV로, 측정 환경은 env-*.txt로 남긴다.
param(
    [Parameter(Mandatory)] [string]$Image,
    [string]$Sruk = "$env:LOCALAPPDATA\Programs\Sruk\sruk.exe",
    [string]$Irfan = "$env:ProgramFiles\IrfanView\i_view64.exe",
    [int]$Runs = 10,
    [int]$IdleMs = 300,
    [int]$TimeoutMs = 15000,
    [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
$Image = (Resolve-Path $Image).Path
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'results' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$tag = [IO.Path]::GetFileNameWithoutExtension($Image)

Add-Type @"
using System; using System.Runtime.InteropServices;
public static class Win {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
}
"@

# ── 측정 환경 기록 ──
function Get-Env {
    $os = Get-CimInstance Win32_OperatingSystem
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $part = Get-Partition -DriveLetter ($Image.Substring(0, 1)) -ErrorAction SilentlyContinue
    $disk = if ($part) { Get-PhysicalDisk | Where-Object DeviceId -eq $part.DiskNumber } else { $null }
    $gpus = (Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name) (드라이버 $($_.DriverVersion))" }) -join ' / '
    $plan = (powercfg /getactivescheme) -replace '^.*:\s*', ''
    $lines = @(
        "측정 시각: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
        "OS: $($os.Caption) $($os.OSArchitecture), 버전 $($cv.DisplayVersion), 빌드 $($cv.CurrentBuild).$($cv.UBR)"
        "CPU: $($cpu.Name.Trim()) ($($cpu.NumberOfCores)코어 $($cpu.NumberOfLogicalProcessors)스레드)"
        "RAM: $([math]::Round($os.TotalVisibleMemorySize / 1MB, 1)) GB"
        "저장장치(사진이 있는 드라이브): $(if ($disk) { "$($disk.FriendlyName), $($disk.MediaType), $($disk.BusType)" } else { '미확인' })"
        "GPU: $gpus"
        "전원 관리 옵션: $plan"
        "Sruk: $Sruk, 버전 $((Get-Item $Sruk).VersionInfo.ProductVersion), $((Get-Item $Sruk).Length) 바이트, SHA256 $((Get-FileHash $Sruk).Hash)"
        "IrfanView: $Irfan, 버전 $((Get-Item $Irfan).VersionInfo.ProductVersion), $((Get-Item $Irfan).Length) 바이트, SHA256 $((Get-FileHash $Irfan).Hash)"
        "사진: $(Split-Path $Image -Leaf), $((Get-Item $Image).Length) 바이트, SHA256 $((Get-FileHash $Image).Hash)"
    )
    Add-Type -AssemblyName System.Drawing
    $img = [System.Drawing.Image]::FromFile($Image); $lines += "사진 해상도: $($img.Width)x$($img.Height)"; $img.Dispose()
    $lines += "측정 직전 5초 동안 CPU 시간을 50ms 이상 쓴 프로세스(코어 하나의 1% 이상):"
    $a = Get-Process | Select-Object Id, ProcessName, @{n = 'Cpu'; e = { $_.TotalProcessorTime.TotalMilliseconds } }
    Start-Sleep -Seconds 5
    $b = Get-Process | Select-Object Id, ProcessName, @{n = 'Cpu'; e = { $_.TotalProcessorTime.TotalMilliseconds } }
    $busy = foreach ($x in $b) { $y = $a | Where-Object Id -eq $x.Id; if ($y -and ($x.Cpu - $y.Cpu) -ge 50) { '  {0} {1:N0} ms' -f $x.ProcessName, ($x.Cpu - $y.Cpu) } }
    $lines += if ($busy) { $busy } else { '  없음' }
    $lines
}

$srukLog = Join-Path $env:TEMP 'sruk_perf.log'
function Measure-Once($name, $exe) {
    $logStart = if ($name -eq 'Sruk' -and (Test-Path $srukLog)) { (Get-Item $srukLog).Length } else { 0 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $exe -ArgumentList "`"$Image`"" -PassThru
    $windowMs = $null; $lastBusy = 0.0; $lastCpu = [TimeSpan]::Zero; $r = $null
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        Start-Sleep -Milliseconds 10
        $p.Refresh()
        if ($p.HasExited) { throw "$name 이(가) 측정 중에 종료됐습니다." }
        $now = $sw.Elapsed.TotalMilliseconds
        if ($null -eq $windowMs -and $p.MainWindowHandle -ne [IntPtr]::Zero) { $windowMs = $now }
        $cpu = $p.TotalProcessorTime
        if ($cpu -ne $lastCpu) { $lastCpu = $cpu; $lastBusy = $now }
        if ($null -ne $windowMs -and ($now - [math]::Max($lastBusy, $windowMs)) -ge $IdleMs) {
            $wr = New-Object Win+RECT; $cr = New-Object Win+RECT
            [void][Win]::GetWindowRect($p.MainWindowHandle, [ref]$wr); [void][Win]::GetClientRect($p.MainWindowHandle, [ref]$cr)
            $r = [ordered]@{
                App = $name; WindowMs = [math]::Round($windowMs, 1); ReadyMs = [math]::Round([math]::Max($lastBusy, $windowMs), 1)
                CpuMs = [math]::Round($cpu.TotalMilliseconds, 0)
                PrivateMB = [math]::Round($p.PrivateMemorySize64 / 1MB, 1); WorkingSetMB = [math]::Round($p.WorkingSet64 / 1MB, 1)
                PeakWorkingSetMB = [math]::Round($p.PeakWorkingSet64 / 1MB, 1)
                Window = '{0}x{1}' -f ($wr.R - $wr.L), ($wr.B - $wr.T); Client = '{0}x{1}' -f $cr.R, $cr.B
                Dpi = [Win]::GetDpiForWindow($p.MainWindowHandle)
                SrukPresentedMs = ''
            }
            break
        }
    }
    if (-not $p.HasExited) { [void]$p.CloseMainWindow(); if (-not $p.WaitForExit(3000)) { Stop-Process -Id $p.Id -Force } }
    Start-Sleep -Milliseconds 500
    if (-not $r) { throw "$name : ${TimeoutMs}ms 안에 측정이 끝나지 않았습니다." }
    # Sruk 내부 기록: 첫 사진을 화면에 그린 시각(프로세스 생성 기준). IrfanView에는 같은 기록이 없다.
    if ($name -eq 'Sruk' -and (Test-Path $srukLog)) {
        $fs = [IO.File]::Open($srukLog, 'Open', 'Read', 'ReadWrite'); [void]$fs.Seek($logStart, 'Begin')
        $txt = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd(); $fs.Close()
        $m = [regex]::Match($txt, 'FIRST_IMAGE_PRESENTED .*?sinceProcStart=([\d.]+)')
        if ($m.Success) { $r.SrukPresentedMs = $m.Groups[1].Value }
    }
    [pscustomobject]$r
}

function Median($xs) { $s = @($xs | ForEach-Object { [double]$_ } | Sort-Object); $n = $s.Count
    if ($n -eq 0) { return $null }; if ($n % 2) { $s[($n - 1) / 2] } else { ($s[$n / 2 - 1] + $s[$n / 2]) / 2 } }

$envFile = Join-Path $OutDir "env-$tag-$stamp.txt"
Get-Env | Set-Content -Path $envFile -Encoding UTF8
$apps = [ordered]@{ Sruk = $Sruk; IrfanView = $Irfan }
Write-Host "사진: $Image"
foreach ($k in $apps.Keys) { Write-Host "예열(기록 제외): $k"; [void](Measure-Once $k $apps[$k]) }
$rows = New-Object System.Collections.ArrayList
for ($i = 1; $i -le $Runs; $i++) {
    $order = if ($i % 2) { @('Sruk', 'IrfanView') } else { @('IrfanView', 'Sruk') }
    $pos = 0
    foreach ($k in $order) {
        $pos++
        $r = Measure-Once $k $apps[$k]
        $r | Add-Member Run $i -PassThru | Add-Member OrderInRun $pos
        [void]$rows.Add($r)
        Write-Host ("[{0}/{1}] {2,-9} 창 {3,6}ms 사진 {4,6}ms 전용 {5,6}MB 작업집합 {6,6}MB" -f $i, $Runs, $k, $r.WindowMs, $r.ReadyMs, $r.PrivateMB, $r.WorkingSetMB)
    }
}
$csv = Join-Path $OutDir "runs-$tag-$stamp.csv"
$rows | Select-Object Run, OrderInRun, App, WindowMs, ReadyMs, SrukPresentedMs, CpuMs, PrivateMB, WorkingSetMB, PeakWorkingSetMB, Window, Client, Dpi |
    Export-Csv $csv -NoTypeInformation -Encoding UTF8

$sum = foreach ($k in $apps.Keys) {
    $s = $rows | Where-Object App -eq $k
    [pscustomobject]@{
        App = $k; N = $s.Count
        WindowMs_median = Median ($s.WindowMs); WindowMs_min = ($s.WindowMs | Measure-Object -Minimum).Minimum; WindowMs_max = ($s.WindowMs | Measure-Object -Maximum).Maximum
        ReadyMs_median = Median ($s.ReadyMs); ReadyMs_min = ($s.ReadyMs | Measure-Object -Minimum).Minimum; ReadyMs_max = ($s.ReadyMs | Measure-Object -Maximum).Maximum
        SrukPresentedMs_median = Median ($s.SrukPresentedMs | Where-Object { $_ -ne '' })
        CpuMs_median = Median ($s.CpuMs)
        PrivateMB_median = Median ($s.PrivateMB); WorkingSetMB_median = Median ($s.WorkingSetMB); PeakWorkingSetMB_median = Median ($s.PeakWorkingSetMB)
        Window = ($s.Window | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
        Client = ($s.Client | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
    }
}
$sumFile = Join-Path $OutDir "summary-$tag-$stamp.csv"
$sum | Export-Csv $sumFile -NoTypeInformation -Encoding UTF8
$sum | Format-List | Out-String | Write-Host
Write-Host "환경: $envFile`n회차별: $csv`n요약: $sumFile"
