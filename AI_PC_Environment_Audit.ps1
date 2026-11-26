# AI PC Environment Audit & Portrait Generator (寻祎居 · 算力底牌侧写)
# Read-only checks. No downloads, installation, changes, or network requests.
[CmdletBinding()]
param(
    [switch]$IncludeSoftwareList,
    [switch]$NoOpenBrowser,
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Continue'
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $scriptDir 'AI_PC_Audit_Result'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$reportPath = Join-Path $OutputDirectory 'AI_PC_Report.txt'
$htmlPath   = Join-Path $OutputDirectory 'index.html'
$jsonPath   = Join-Path $OutputDirectory 'AI_PC_Snapshot.json'
$prevJsonPath = Join-Path $OutputDirectory 'AI_PC_Snapshot_Prev.json'

if (Test-Path $jsonPath) {
    Copy-Item -LiteralPath $jsonPath -Destination $prevJsonPath -Force -ErrorAction SilentlyContinue
}

$report = New-Object 'System.Collections.Generic.List[string]'

function Add-Line([object]$Value = '') {
    $s = [string]$Value
    if ($env:USERPROFILE) { $s = $s.Replace($env:USERPROFILE, '%USERPROFILE%') }
    [void]$script:report.Add($s)
}
function Add-Section([string]$Name) {
    Add-Line ''
    Add-Line ('=' * 18 + ' ' + $Name + ' ' + '=' * 18)
}
function Add-Check([string]$Name, [scriptblock]$Check) {
    Add-Line ("-- $Name --")
    try {
        $result = & $Check 2>&1 | Out-String -Width 180
        if ([string]::IsNullOrWhiteSpace($result)) { Add-Line '(no output)' }
        else { Add-Line $result.TrimEnd() }
    }
    catch { Add-Line ("ERROR: " + $_.Exception.Message) }
}
function Get-ToolVersion([string]$Name, [string[]]$Arguments = @('--version')) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { return $null }
    try {
        $out = & $Name @Arguments 2>&1 | Select-Object -First 2 | Out-String -Width 180
        $clean = ($out -split "`r?`n" | Where-Object { $_ -and ($_ -notmatch 'CategoryInfo|FullyQualifiedErrorId|At line:') } | Select-Object -First 1)
        if ($clean) { return $clean.Trim() }
        return $out.Trim()
    }
    catch { return $null }
}
function Add-Version([string]$Name, [string[]]$Arguments = @('--version')) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { Add-Line ("$Name : not found in this PowerShell session's PATH") ; return }
    try {
        $out = & $Name @Arguments 2>&1 | Select-Object -First 6 | Out-String -Width 180
        Add-Line ("$Name : " + $out.Trim())
    }
    catch { Add-Line ("$Name : error - " + $_.Exception.Message) }
}

Write-Host "[1/4] 正在采集电脑硬件、磁盘与操作系统信息..." -ForegroundColor Cyan

$nowStr = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
$hourNow = (Get-Date).Hour
$dayOfWeekMap = @{ 'Monday'='周一'; 'Tuesday'='周二'; 'Wednesday'='周三'; 'Thursday'='周四'; 'Friday'='周五'; 'Saturday'='周六'; 'Sunday'='周日' }
$cnDay = $dayOfWeekMap[(Get-Date).DayOfWeek.ToString()]
$timePeriod = if ($hourNow -lt 6) { '凌晨' } elseif ($hourNow -lt 12) { '上午' } elseif ($hourNow -lt 14) { '中午' } elseif ($hourNow -lt 18) { '下午' } else { '晚上' }

# Structured data collection for HTML rendering
$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$bb = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue
$bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
$cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
$rams = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
$gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
$disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)

$brand = if ($cs.Manufacturer) { $cs.Manufacturer.Trim() } else { '未知品牌' }
$model = if ($cs.Model) { $cs.Model.Trim() } else { '通用 PC' }
$ramGB = if ($cs.TotalPhysicalMemory) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 2) } else { 0 }
$osCaption = if ($os.Caption) { $os.Caption.Trim() } else { 'Windows' }
$osBuild = if ($os.BuildNumber) { $os.BuildNumber } else { '' }
$boardProduct = if ($bb.Product) { $bb.Product.Trim() } else { 'UnknownBoard' }
$biosVer = if ($bios.SMBIOSBIOSVersion) { $bios.SMBIOSBIOSVersion.Trim() } else { '' }
$cpuName = if ($cpu.Name) { $cpu.Name.Trim() } else { (Get-ItemProperty "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0" -ErrorAction SilentlyContinue).ProcessorNameString }
$cpuCores = if ($cpu.NumberOfCores) { $cpu.NumberOfCores } else { 0 }
$cpuThreads = if ($cpu.NumberOfLogicalProcessors) { $cpu.NumberOfLogicalProcessors } else { 0 }

$ramModulesSummary = if ($rams.Count -gt 0) {
    $stickGB = [math]::Round($rams[0].Capacity / 1GB, 0)
    $stickSpeed = $rams[0].Speed
    $stickMaker = ($rams[0].Manufacturer -replace '\s+',' ').Trim()
    "$($rams.Count) 根 ${stickGB}GB ($stickMaker ${stickSpeed}MHz)"
} else {
    "${ramGB} GB"
}

$diskList = @()
$maxFreeDisk = $null
foreach ($d in $disks) {
    $tGB = [math]::Round($d.Size / 1GB, 1)
    $fGB = [math]::Round($d.FreeSpace / 1GB, 1)
    $obj = [PSCustomObject]@{ Drive = $d.DeviceID; TotalGB = $tGB; FreeGB = $fGB }
    $diskList += $obj
    if (-not $maxFreeDisk -or $fGB -gt $maxFreeDisk.FreeGB) { $maxFreeDisk = $obj }
}
$cDrive = $diskList | Where-Object { $_.Drive -eq 'C:' } | Select-Object -First 1

Write-Host "[2/4] 正在检测显卡、显存占用与 CUDA 驱动状态..." -ForegroundColor Cyan

$gpuName = '未检测到独立 NVIDIA 显卡'
$vramTotalMiB = 0
$vramUsedMiB = 0
$vramFreeMiB = 0
$nvDriver = 'N/A'
$cudaMax = 'N/A'
$gpuTemp = 'N/A'
$gpuPowerDraw = 'N/A'
$gpuPowerCap = 'N/A'
$gpuPerfState = 'N/A'

if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    try {
        $smiCsv = & nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,driver_version,temperature.gpu,power.draw,power.limit,pstate --format=csv,noheader,nounits 2>$null | Select-Object -First 1
        if ($smiCsv) {
            $parts = $smiCsv -split ',\s*'
            if ($parts.Count -ge 5) {
                $gpuName = $parts[0].Trim()
                $vramTotalMiB = [int]($parts[1] -replace '[^\d]','')
                $vramUsedMiB  = [int]($parts[2] -replace '[^\d]','')
                $vramFreeMiB  = [int]($parts[3] -replace '[^\d]','')
                $nvDriver     = $parts[4].Trim()
            }
            if ($parts.Count -ge 9) {
                $gpuTemp      = $parts[5].Trim() + '°C'
                $gpuPowerDraw = $parts[6].Trim() + 'W'
                $gpuPowerCap  = $parts[7].Trim() + 'W'
                $gpuPerfState = $parts[8].Trim()
            }
        }
        $smiHeader = & nvidia-smi 2>$null | Select-Object -First 5 | Out-String
        if ($smiHeader -match 'CUDA Version:\s*([\d\.]+)') {
            $cudaMax = $Matches[1]
        }
    } catch {}
} elseif ($gpus.Count -gt 0) {
    $gpuName = ($gpus | Select-Object -Last 1).Name
}

$nvccVer = Get-ToolVersion 'nvcc' @('--version')

Write-Host "[3/4] 正在盘点编程工具链、Conda 环境与 PyTorch CUDA 状态..." -ForegroundColor Cyan

$pyVer     = Get-ToolVersion 'python'
$condaVer  = Get-ToolVersion 'conda'
$uvVer     = Get-ToolVersion 'uv'
$gitVer    = Get-ToolVersion 'git'
$nodeVer   = Get-ToolVersion 'node'
$npmVer    = Get-ToolVersion 'npm'
$pnpmVer   = Get-ToolVersion 'pnpm'
$rustVer   = Get-ToolVersion 'rustc'
$dotnetVer = Get-ToolVersion 'dotnet'
$dockerVer = Get-ToolVersion 'docker'
$codeVer   = Get-ToolVersion 'code'
$ollamaVer = Get-ToolVersion 'ollama'
$ffmpegVer = Get-ToolVersion 'ffmpeg' @('-version')

$condaEnvs = @()
if (Get-Command conda -ErrorAction SilentlyContinue) {
    try {
        $envLines = & conda info --envs 2>$null
        foreach ($line in $envLines) {
            if ($line -match '^\s*([a-zA-Z0-9_\-\.]+)\s+[\*\+]?\s*([A-Za-z]:\\.+)$') {
                $condaEnvs += $Matches[1]
            }
        }
    } catch {}
}

$torchVer = '未安装'
$torchCudaVer = 'None'
$torchCudaAvail = 'False'
$transformersVer = '未安装'
$diffusersVer = '未安装'
$onnxVer = '未安装'

if (Get-Command python -ErrorAction SilentlyContinue) {
    $pyMiniProbe = @'
import importlib.metadata as md
def v(n):
    try: return md.version(n)
    except: return "not_installed"
print("TORCH=" + v("torch"))
print("TRANSFORMERS=" + v("transformers"))
print("DIFFUSERS=" + v("diffusers"))
print("ONNX=" + v("onnxruntime"))
try:
    import torch
    print("CUDA_RT=" + str(torch.version.cuda))
    print("CUDA_OK=" + str(torch.cuda.is_available()))
except:
    print("CUDA_RT=None")
    print("CUDA_OK=False")
'@
    try {
        $probeLines = & python -c $pyMiniProbe 2>$null
        foreach ($l in $probeLines) {
            if ($l -match '^TORCH=(.+)$') { $torchVer = $Matches[1] }
            if ($l -match '^TRANSFORMERS=(.+)$') { $transformersVer = $Matches[1] }
            if ($l -match '^DIFFUSERS=(.+)$') { $diffusersVer = $Matches[1] }
            if ($l -match '^ONNX=(.+)$') { $onnxVer = $Matches[1] }
            if ($l -match '^CUDA_RT=(.+)$') { $torchCudaVer = $Matches[1] }
            if ($l -match '^CUDA_OK=(.+)$') { $torchCudaAvail = $Matches[1] }
        }
    } catch {}
}

# Build standard text report (AI_PC_Report.txt)
Add-Line 'AI PC ENVIRONMENT AUDIT (READ-ONLY)'
Add-Line ('Date (local): ' + $nowStr)
Add-Line ('PowerShell: ' + $PSVersionTable.PSVersion.ToString())
Add-Line 'Report path uses a local folder next to this script unless overridden.'
Add-Line 'WARNING: Review this report before sharing: package names, environment names and custom paths may be personal.'

Add-Section 'WINDOWS AND COMPUTER MODEL'
Add-Check 'Computer brand, model and physical RAM' {
    $cs | Select-Object Manufacturer, Model, @{Name='RAM_GB';Expression={[math]::Round($_.TotalPhysicalMemory / 1GB, 2)}} | Format-List
}
Add-Check 'Operating system' {
    $os | Select-Object Caption,Version,BuildNumber,OSArchitecture | Format-List
}
Add-Check 'Motherboard and BIOS (no serial number)' {
    $bb | Select-Object Manufacturer,Product | Format-List
    $bios | Select-Object Manufacturer,SMBIOSBIOSVersion,ReleaseDate | Format-List
}
Add-Check 'CPU' {
    $cpu | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed | Format-List
}
Add-Check 'Physical RAM modules (no serial numbers)' {
    $rams | Select-Object DeviceLocator,Manufacturer,PartNumber,@{Name='Capacity_GB';Expression={[math]::Round($_.Capacity / 1GB, 2)}},Speed | Format-Table -AutoSize
}
Add-Check 'GPU devices and driver versions (Windows)' {
    $gpus | Select-Object Name,DriverVersion,VideoProcessor | Format-List
}
Add-Check 'Disk space (local drives only)' {
    $disks | Select-Object DeviceID,@{Name='Total_GB';Expression={[math]::Round($_.Size / 1GB, 1)}},@{Name='Free_GB';Expression={[math]::Round($_.FreeSpace / 1GB, 1)}} | Format-Table -AutoSize
}

Add-Section 'GPU / NVIDIA CUDA'
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    Add-Check 'GPU memory (actual dedicated GPU VRAM, NVIDIA driver)' {
        & nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,driver_version --format=csv
    }
    Add-Check 'NVIDIA driver-reported maximum supported CUDA version' {
        & nvidia-smi | Select-Object -First 14
    }
} else { Add-Line 'nvidia-smi is not in PATH, or the NVIDIA driver/tool is unavailable.' }
if (Get-Command nvcc -ErrorAction SilentlyContinue) {
    Add-Check 'Installed CUDA Toolkit compiler (nvcc)' { & nvcc --version }
} else { Add-Line 'nvcc not found. This does NOT mean CUDA GPU inference is unavailable.' }

Add-Section 'PROGRAMMING AND DEVELOPMENT TOOLS'
Add-Version 'python'
Add-Version 'py' @('--version')
Add-Version 'conda'
Add-Version 'pip'
Add-Version 'uv'
Add-Version 'git'
Add-Version 'node'
Add-Version 'npm'
Add-Version 'pnpm'
Add-Version 'java' @('-version')
Add-Version 'dotnet'
Add-Version 'rustc'
Add-Version 'cargo'
Add-Version 'docker'
Add-Version 'ollama'
Add-Version 'ffmpeg'
Add-Version 'code'
Add-Version 'winget'

Add-Section 'PYTHON / CONDA ENVIRONMENTS'
if (Get-Command conda -ErrorAction SilentlyContinue) {
    Add-Check 'Conda environment list' { & conda info --envs }
    Add-Check 'Current Conda environment' { $env:CONDA_DEFAULT_ENV }
} else { Add-Line 'Conda not found in this shell. It may be installed but not activated or on PATH.' }
if (Get-Command python -ErrorAction SilentlyContinue) {
    $pythonProbe = @'
import sys
import importlib.metadata as md
print('Python executable:', sys.executable)
print('Python version:', sys.version.split()[0])
for name in ('torch','torchvision','torchaudio','xformers','transformers','diffusers','safetensors','accelerate','onnxruntime','gradio','opencv-python','numpy'):
    try: print(name + ':', md.version(name))
    except md.PackageNotFoundError: print(name + ': not installed in this Python environment')
try:
    import torch
    print('torch CUDA runtime:', torch.version.cuda)
    print('torch CUDA available:', torch.cuda.is_available())
    if torch.cuda.is_available():
        for i in range(torch.cuda.device_count()):
            p = torch.cuda.get_device_properties(i)
            print('Torch GPU %s: %s, dedicated VRAM: %.2f GiB' % (i,p.name,p.total_memory/1024**3))
except Exception as e:
    print('PyTorch probe:', type(e).__name__, str(e)[:400])
'@
    Add-Check 'Python AI libraries (current environment only)' { & python -c $pythonProbe }
}
Add-Section 'INSTALLED SOFTWARE'
if ($IncludeSoftwareList) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Add-Check 'WinGet installed applications (may contain personal application names)' { & winget list --disable-interactivity }
    } else { Add-Line 'winget not found.' }
} else {
    Add-Line 'Full application inventory omitted for privacy and brevity.'
    Add-Line 'Re-run with -IncludeSoftwareList to include a WinGet package list.'
}
Add-Section 'INTERPRETATION NOTES'
Add-Line '1. NVIDIA-SMI shows dedicated NVIDIA VRAM; shared Windows graphics memory is NOT additional physical VRAM.'
Add-Line '2. CUDA in NVIDIA-SMI is the supported maximum version, not necessarily an installed CUDA Toolkit.'
Add-Line '3. A Python package list applies to the current environment only; ComfyUI Desktop may use a separate Python runtime.'
Add-Line '4. This script inventories software and hardware; it does not benchmark or guarantee AI model compatibility.'
Add-Line '5. For a model-specific verdict, test the exact checkpoint, precision, workflow, resolution, frame count and GPU peak memory.'

$report | Set-Content -LiteralPath $reportPath -Encoding UTF8

Write-Host "[4/4] 正在生成「你是谁 · AI 眼里的这台电脑」可视化侧写页面..." -ForegroundColor Cyan

# Save current snapshot JSON for diffing
$vramTotalGB = [math]::Round($vramTotalMiB / 1024, 1)
$vramFreeGB  = [math]::Round($vramFreeMiB / 1024, 2)
$vramUsedGB  = [math]::Round($vramUsedMiB / 1024, 2)
$customEnvs  = @($condaEnvs | Where-Object { $_ -ne 'base' })
$fpId = ("XYJ-{0}-{1}G-{2}C-E{3}" -f ($boardProduct -replace '[^A-Za-z0-9]',''), [math]::Round($vramTotalGB,0), $cpuCores, $customEnvs.Count).ToUpper()

$snapshotObj = [ordered]@{
    timestamp = $nowStr
    fingerprintId = $fpId
    brand = $brand
    model = $model
    os = $osCaption
    osBuild = $osBuild
    board = $boardProduct
    bios = $biosVer
    cpu = $cpuName
    cpuCores = $cpuCores
    cpuThreads = $cpuThreads
    ramGB = $ramGB
    ramModules = $ramModulesSummary
    gpu = $gpuName
    vramTotalMiB = $vramTotalMiB
    vramUsedMiB = $vramUsedMiB
    vramFreeMiB = $vramFreeMiB
    nvDriver = $nvDriver
    cudaMax = $cudaMax
    gpuTemp = $gpuTemp
    gpuPowerDraw = $gpuPowerDraw
    gpuPowerCap = $gpuPowerCap
    gpuPerfState = $gpuPerfState
    disks = $diskList
    tools = [ordered]@{
        python = if ($pyVer) { $pyVer } else { '未检出' }
        conda  = if ($condaVer) { $condaVer } else { '未检出' }
        uv     = if ($uvVer) { $uvVer } else { '未检出' }
        git    = if ($gitVer) { $gitVer } else { '未检出' }
        node   = if ($nodeVer) { $nodeVer } else { '未检出' }
        pnpm   = if ($pnpmVer) { $pnpmVer } else { '未检出' }
        rust   = if ($rustVer) { $rustVer } else { '未检出' }
        dotnet = if ($dotnetVer) { $dotnetVer } else { '未检出' }
        docker = if ($dockerVer) { $dockerVer } else { '未检出' }
        code   = if ($codeVer) { $codeVer } else { '未检出' }
        ffmpeg = if ($ffmpegVer) { '已就绪' } else { '未检出' }
        nvcc   = if ($nvccVer) { '已安装' } else { '未安装系统级 nvcc' }
    }
    condaEnvs = $customEnvs
    torch = [ordered]@{
        version = $torchVer
        cudaRuntime = $torchCudaVer
        cudaAvailable = $torchCudaAvail
        transformers = $transformersVer
        onnxruntime = $onnxVer
    }
    timeInfo = [ordered]@{
        cnDay = $cnDay
        timePeriod = $timePeriod
        hour = $hourNow
    }
}

$snapshotJsonStr = $snapshotObj | ConvertTo-Json -Depth 6
$snapshotJsonStr | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$prevJsonStr = "null"
if (Test-Path $prevJsonPath) {
    $prevJsonStr = Get-Content -LiteralPath $prevJsonPath -Raw -Encoding UTF8
}

$rawReportEscaped = ($report -join "`n") | ConvertTo-Json

# Generate standalone HTML with embedded JSON and humanized Chinese rendering
$htmlTemplate = @'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>寻祎居 · 算力底牌侧写 | AI 眼里的这台电脑</title>
  <style>
    :root {
      --bg-base: #0b0d11;
      --bg-card: #12151c;
      --bg-card-elevated: #171b24;
      --bg-card-subtle: #0e1117;
      --border-subtle: rgba(255, 255, 255, 0.08);
      --border-focus: rgba(255, 255, 255, 0.18);
      --text-primary: #e8ecf2;
      --text-white: #ffffff;
      --text-secondary: #9ba3b2;
      --text-muted: #5e6675;
      --accent-red: #ff4d4f;
      --accent-red-bg: rgba(255, 77, 79, 0.12);
      --accent-amber: #f59e0b;
      --accent-amber-bg: rgba(245, 158, 11, 0.12);
      --accent-green: #10b981;
      --accent-green-bg: rgba(16, 185, 129, 0.12);
      --accent-cyan: #38bdf8;
      --font-sans: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
      --font-mono: "JetBrains Mono", "Cascadia Code", "Consolas", "SFMono-Regular", monospace;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background-color: var(--bg-base);
      background-image:
        radial-gradient(circle at 18% 12%, rgba(16, 185, 129, 0.05) 0%, transparent 38%),
        radial-gradient(circle at 82% 18%, rgba(255, 77, 79, 0.05) 0%, transparent 40%);
      color: var(--text-primary);
      font-family: var(--font-sans);
      line-height: 1.65;
      min-height: 100vh;
      padding: 24px 28px 64px;
      -webkit-font-smoothing: antialiased;
    }
    .container { max-width: 1360px; margin: 0 auto; }
    .topbar {
      display: flex; align-items: center; justify-content: space-between;
      padding-bottom: 18px; margin-bottom: 24px;
      border-bottom: 1px solid var(--border-subtle);
      flex-wrap: wrap; gap: 12px;
    }
    .brand-group { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
    .brand-badge {
      display: inline-flex; align-items: center; gap: 6px;
      padding: 4px 10px; border-radius: 6px;
      background: rgba(255, 255, 255, 0.05);
      border: 1px solid var(--border-subtle);
      font-size: 12px; color: var(--text-secondary);
    }
    .brand-badge .dot {
      width: 6px; height: 6px; border-radius: 50%;
      background: var(--accent-green); box-shadow: 0 0 8px var(--accent-green);
    }
    .brand-title { font-size: 16px; font-weight: 600; color: var(--text-white); }
    .brand-sub { font-size: 13px; color: var(--text-muted); }
    .legend-bar {
      display: flex; align-items: center; gap: 18px;
      font-size: 12.5px; color: var(--text-secondary);
      background: var(--bg-card-subtle); padding: 6px 14px;
      border-radius: 999px; border: 1px solid var(--border-subtle);
      flex-wrap: wrap;
    }
    .legend-item { display: inline-flex; align-items: center; gap: 6px; }
    .legend-red-dot {
      width: 7px; height: 7px; border-radius: 50%;
      background: var(--accent-red); box-shadow: 0 0 6px var(--accent-red);
    }
    .legend-white-fact {
      display: inline-block; width: 14px; height: 3px;
      background: var(--text-white); border-radius: 2px;
    }
    .legend-green-dash {
      display: inline-block; width: 16px; height: 0;
      border-bottom: 2px dashed var(--accent-green);
    }
    .main-grid {
      display: grid;
      grid-template-columns: minmax(0, 7fr) minmax(320px, 3fr);
      gap: 24px; align-items: start;
    }
    @media (max-width: 1024px) { .main-grid { grid-template-columns: 1fr; } }
    .card {
      background: var(--bg-card);
      border: 1px solid var(--border-subtle);
      border-radius: 16px; padding: 28px 30px;
      box-shadow: 0 14px 40px rgba(0, 0, 0, 0.35);
      position: relative;
    }
    .card-header {
      display: flex; align-items: baseline; justify-content: space-between;
      margin-bottom: 22px; flex-wrap: wrap; gap: 10px;
    }
    .card-eyebrow {
      font-size: 11px; text-transform: uppercase;
      letter-spacing: 0.1em; color: var(--text-muted);
      font-family: var(--font-mono);
    }
    .card-title { font-size: 22px; font-weight: 700; color: var(--text-white); }
    .card-meta { font-size: 12px; color: var(--text-muted); font-family: var(--font-mono); }
    .narrative-body {
      display: flex; flex-direction: column; gap: 15px;
      font-size: 15.5px; line-height: 1.85; color: #c5cddb;
    }
    .narrative-p {
      padding: 10px 14px; border-radius: 10px;
      background: rgba(255, 255, 255, 0.014);
      border-left: 2px solid rgba(255, 255, 255, 0.07);
      transition: background 0.2s ease, border-color 0.2s ease;
    }
    .narrative-p:hover {
      background: rgba(255, 255, 255, 0.03);
      border-left-color: rgba(255, 255, 255, 0.22);
    }
    .p-index {
      font-family: var(--font-mono); font-size: 11px;
      color: var(--text-muted); margin-right: 8px; user-select: none;
    }
    .clue {
      cursor: pointer; position: relative;
      transition: all 0.15s ease; padding: 1px 4px;
      border-radius: 4px; display: inline;
    }
    .clue-red {
      color: #ff9a9c; font-weight: 600;
      background: rgba(255, 77, 79, 0.1);
      border-bottom: 1.5px solid rgba(255, 77, 79, 0.55);
      padding-left: 15px;
    }
    .clue-red::before {
      content: ""; position: absolute; left: 5px; top: 50%;
      transform: translateY(-50%); width: 6px; height: 6px;
      border-radius: 50%; background: var(--accent-red);
      box-shadow: 0 0 6px var(--accent-red);
    }
    .clue-red:hover, .clue-red.active { background: rgba(255, 77, 79, 0.22); color: #ffffff; }
    .clue-fact {
      color: var(--text-white); font-weight: 600;
      background: rgba(255, 255, 255, 0.06);
      border-bottom: 1px solid rgba(255, 255, 255, 0.28);
    }
    .clue-fact:hover, .clue-fact.active { background: rgba(255, 255, 255, 0.15); border-bottom-color: var(--text-white); }
    .clue-infer {
      color: #6ee7b7; border-bottom: 1.5px dashed var(--accent-green);
      background: rgba(16, 185, 129, 0.07);
    }
    .clue-infer:hover, .clue-infer.active { background: rgba(16, 185, 129, 0.18); color: #a7f3d0; }
    .fingerprint-box {
      margin-top: 24px; padding: 18px 20px; border-radius: 12px;
      background: var(--bg-card-subtle); border: 1px solid var(--border-subtle);
      display: grid; grid-template-columns: 1.15fr 1fr; gap: 18px; align-items: center;
    }
    @media (max-width: 768px) { .fingerprint-box { grid-template-columns: 1fr; } }
    .fp-left { display: flex; flex-direction: column; gap: 6px; }
    .fp-label { font-size: 11.5px; color: var(--text-muted); display: flex; align-items: center; gap: 8px; }
    .fp-id {
      font-family: var(--font-mono); font-size: 17px; font-weight: 700;
      color: var(--text-white); letter-spacing: 0.04em;
    }
    .fp-tag {
      font-size: 11px; font-weight: 500; padding: 2px 8px; border-radius: 4px;
      background: rgba(56, 189, 248, 0.12); color: var(--accent-cyan);
      border: 1px solid rgba(56, 189, 248, 0.25);
    }
    .fp-sub { font-size: 12px; color: var(--text-secondary); }
    .fp-diff {
      border-left: 1px solid var(--border-subtle); padding-left: 18px;
      display: flex; flex-direction: column; gap: 6px;
    }
    @media (max-width: 768px) {
      .fp-diff { border-left: none; border-top: 1px solid var(--border-subtle); padding-left: 0; padding-top: 12px; }
    }
    .diff-title { font-size: 12px; font-weight: 600; color: var(--text-secondary); display: flex; align-items: center; justify-content: space-between; }
    .diff-badge { font-size: 11px; color: var(--accent-green); background: var(--accent-green-bg); padding: 1px 7px; border-radius: 99px; font-family: var(--font-mono); }
    .diff-list { list-style: none; font-size: 12.5px; color: var(--text-secondary); display: flex; flex-direction: column; gap: 3px; }
    .diff-plus { color: var(--accent-green); font-family: var(--font-mono); font-weight: 700; margin-right: 4px; }
    .action-bar { margin-top: 20px; display: flex; flex-wrap: wrap; gap: 10px; }
    .btn {
      appearance: none; background: var(--bg-card-elevated);
      border: 1px solid var(--border-subtle); color: var(--text-primary);
      padding: 9px 15px; border-radius: 8px; font-size: 13px; font-weight: 500;
      cursor: pointer; display: inline-flex; align-items: center; gap: 7px;
      transition: all 0.15s ease; font-family: var(--font-sans);
    }
    .btn:hover { background: rgba(255, 255, 255, 0.08); border-color: var(--border-focus); color: var(--text-white); transform: translateY(-1px); }
    .btn-primary { background: rgba(16, 185, 129, 0.14); border-color: rgba(16, 185, 129, 0.4); color: #6ee7b7; }
    .btn-primary:hover { background: rgba(16, 185, 129, 0.24); border-color: var(--accent-green); color: #ffffff; }
    .diag-card { position: sticky; top: 24px; }
    .diag-hero { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 16px; }
    .diag-count-wrap { display: flex; align-items: baseline; gap: 10px; }
    .diag-big-num { font-size: 46px; font-weight: 800; line-height: 1; color: var(--accent-red); font-family: var(--font-mono); text-shadow: 0 0 24px rgba(255, 77, 79, 0.35); }
    .diag-count-text { font-size: 15px; font-weight: 600; color: var(--text-white); }
    .grade-badge { padding: 5px 11px; border-radius: 8px; font-size: 12px; font-weight: 700; background: var(--accent-amber-bg); color: var(--accent-amber); border: 1px solid rgba(245, 158, 11, 0.35); white-space: nowrap; }
    .segment-wrap { margin-bottom: 20px; }
    .segment-bar { display: flex; gap: 4px; height: 8px; border-radius: 99px; overflow: hidden; margin-bottom: 8px; }
    .seg-red { background: var(--accent-red); }
    .seg-amber { background: var(--accent-amber); }
    .seg-green { background: var(--accent-green); }
    .segment-labels { display: flex; justify-content: space-between; font-size: 11.5px; color: var(--text-muted); }
    .priority-box { background: rgba(255, 77, 79, 0.06); border: 1px solid rgba(255, 77, 79, 0.25); border-radius: 12px; padding: 15px 16px; margin-bottom: 18px; }
    .priority-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 10px; }
    .priority-title { font-size: 13.5px; font-weight: 700; color: #ff9a9c; }
    .priority-tag { font-size: 11px; padding: 1px 7px; border-radius: 4px; background: rgba(255, 77, 79, 0.18); color: #ffb3b5; font-family: var(--font-mono); }
    .priority-list { list-style: none; display: flex; flex-direction: column; gap: 10px; font-size: 13px; }
    .priority-item { display: flex; flex-direction: column; gap: 3px; padding-bottom: 8px; border-bottom: 1px dashed rgba(255, 255, 255, 0.07); }
    .priority-item:last-child { padding-bottom: 0; border-bottom: none; }
    .priority-item-head { font-weight: 600; color: var(--text-white); }
    .priority-item-desc { color: var(--text-secondary); font-size: 12.2px; line-height: 1.5; }
    .priority-cmd { margin-top: 3px; font-family: var(--font-mono); font-size: 11.2px; background: rgba(0, 0, 0, 0.35); color: #93c5fd; padding: 4px 8px; border-radius: 5px; border: 1px solid rgba(255, 255, 255, 0.06); overflow-x: auto; white-space: nowrap; }
    .checklist-section-title { font-size: 12px; font-weight: 600; color: var(--text-muted); letter-spacing: 0.06em; margin-bottom: 10px; }
    .checklist { list-style: none; display: flex; flex-direction: column; gap: 10px; }
    .check-item { display: flex; align-items: flex-start; gap: 10px; padding: 10px 12px; border-radius: 10px; background: var(--bg-card-subtle); border: 1px solid var(--border-subtle); font-size: 13px; line-height: 1.5; }
    .check-dot { width: 8px; height: 8px; border-radius: 50%; margin-top: 6px; flex-shrink: 0; }
    .dot-red { background: var(--accent-red); box-shadow: 0 0 6px var(--accent-red); }
    .dot-amber { background: var(--accent-amber); box-shadow: 0 0 6px var(--accent-amber); }
    .dot-green { background: var(--accent-green); box-shadow: 0 0 6px var(--accent-green); }
    .check-title { font-weight: 600; color: var(--text-primary); margin-bottom: 2px; }
    .check-note { font-size: 12px; color: var(--text-secondary); }
    .appendix-card {
      margin-top: 22px; background: rgba(14, 17, 23, 0.72);
      border: 1px solid rgba(255, 255, 255, 0.05); border-radius: 14px;
      padding: 20px 24px; opacity: 0.86; transition: opacity 0.2s ease;
    }
    .appendix-card:hover { opacity: 1; }
    .appendix-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 14px; gap: 12px; flex-wrap: wrap; }
    .appendix-title { font-size: 13.5px; font-weight: 600; color: var(--text-secondary); }
    .appendix-filter { background: var(--bg-base); border: 1px solid var(--border-subtle); color: var(--text-primary); padding: 5px 11px; border-radius: 6px; font-size: 12px; width: 220px; outline: none; }
    .appendix-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 6px 20px; font-size: 12px; font-family: var(--font-mono); }
    @media (max-width: 768px) { .appendix-grid { grid-template-columns: 1fr; } }
    .kv-row { display: flex; justify-content: space-between; align-items: baseline; padding: 5px 8px; border-bottom: 1px solid rgba(255, 255, 255, 0.04); gap: 10px; }
    .kv-key { color: var(--text-muted); white-space: nowrap; flex-shrink: 0; }
    .kv-val { color: var(--text-secondary); text-align: right; word-break: break-all; }
    .kv-val.val-warn { color: #fca5a5; }
    .kv-val.val-ok { color: #86efac; }
    .clue-popover {
      position: fixed; z-index: 9999; width: 340px; max-width: calc(100vw - 24px);
      background: #181c26; border: 1px solid rgba(255, 255, 255, 0.18);
      border-radius: 12px; padding: 14px 16px; box-shadow: 0 18px 48px rgba(0, 0, 0, 0.65);
      pointer-events: none; opacity: 0; transform: translateY(6px);
      transition: opacity 0.14s ease, transform 0.14s ease;
    }
    .clue-popover.visible { opacity: 1; transform: translateY(0); pointer-events: auto; }
    .pop-type { font-size: 11px; font-weight: 700; margin-bottom: 4px; display: flex; align-items: center; justify-content: space-between; }
    .pop-type.type-red { color: var(--accent-red); }
    .pop-type.type-fact { color: var(--text-white); }
    .pop-type.type-infer { color: var(--accent-green); }
    .pop-field { font-family: var(--font-mono); font-size: 11.5px; color: var(--accent-cyan); background: rgba(56, 189, 248, 0.1); padding: 3px 7px; border-radius: 4px; margin-bottom: 8px; word-break: break-all; }
    .pop-reason { font-size: 12.8px; color: var(--text-primary); line-height: 1.55; }
    .toast {
      position: fixed; bottom: 24px; right: 24px; background: #1e2430;
      color: var(--text-white); border: 1px solid var(--border-focus);
      padding: 10px 16px; border-radius: 8px; font-size: 13px;
      box-shadow: 0 10px 30px rgba(0,0,0,0.5); opacity: 0;
      transform: translateY(10px); transition: all 0.2s ease; pointer-events: none; z-index: 10000;
    }
    .toast.show { opacity: 1; transform: translateY(0); }
    .modal-backdrop {
      position: fixed; inset: 0; background: rgba(0, 0, 0, 0.72);
      backdrop-filter: blur(4px); display: none; align-items: center;
      justify-content: center; z-index: 9998; padding: 20px;
    }
    .modal-backdrop.open { display: flex; }
    .modal-box {
      background: var(--bg-card); border: 1px solid var(--border-focus);
      border-radius: 14px; width: 100%; max-width: 860px; max-height: 82vh;
      display: flex; flex-direction: column; overflow: hidden;
    }
    .modal-head { padding: 14px 20px; border-bottom: 1px solid var(--border-subtle); display: flex; align-items: center; justify-content: space-between; font-weight: 600; }
    .modal-pre { padding: 18px 20px; overflow-y: auto; font-family: var(--font-mono); font-size: 12px; line-height: 1.6; color: var(--text-secondary); white-space: pre-wrap; }
  </style>
</head>
<body>
  <div class="container">
    <header class="topbar">
      <div class="brand-group">
        <span class="brand-badge"><span class="dot"></span>寻祎居 · 算力底牌侧写</span>
        <h1 class="brand-title">你是谁 · AI 眼里的这台电脑</h1>
        <span class="brand-sub">零联网本地只读扫描</span>
      </div>
      <div class="legend-bar">
        <span class="legend-item"><span class="legend-red-dot"></span>红点：会卡住你的短板</span>
        <span class="legend-item"><span class="legend-white-fact"></span>白字：机子实测数据</span>
        <span class="legend-item"><span class="legend-green-dash"></span>绿虚线：使用习惯侧写（悬停或点按看依据）</span>
      </div>
    </header>

    <main class="main-grid">
      <section class="left-col">
        <article class="card">
          <div class="card-header">
            <div>
              <div class="card-eyebrow">LOCAL AI CAPABILITY PORTRAIT</div>
              <h2 class="card-title">「AI 模型眼里的你」</h2>
            </div>
            <div class="card-meta" id="metaTimestamp"></div>
          </div>

          <div class="narrative-body" id="narrativeContainer"></div>

          <div class="fingerprint-box">
            <div class="fp-left">
              <div class="fp-label">
                <span>本机特征指纹 ID</span>
                <span class="fp-tag">本地生成</span>
              </div>
              <div class="fp-id" id="fpHashText"></div>
              <div class="fp-sub" id="fpSubText"></div>
            </div>
            <div class="fp-diff">
              <div class="diff-title">
                <span>跟上回扫描比有什么变化</span>
                <span class="diff-badge" id="diffBadge">首次扫描</span>
              </div>
              <ul class="diff-list" id="diffList"></ul>
            </div>
          </div>

          <div class="action-bar">
            <button class="btn btn-primary" id="btnCopyPortrait" type="button">📋 复制这段侧写</button>
            <button class="btn" id="btnCopyJson" type="button">🧬 导出 JSON 快照</button>
            <button class="btn" id="btnToggleClues" type="button">💡 展开所有判断依据</button>
            <button class="btn" id="btnViewRaw" type="button">📄 看原始 Report.txt</button>
            <button class="btn" id="btnCopyCmd" type="button">⚡ 复制重测命令</button>
          </div>
        </article>

        <section class="appendix-card">
          <div class="appendix-header">
            <div class="appendix-title" id="appendixTitle">全部探测项和读到的值</div>
            <input type="search" id="appendixSearch" class="appendix-filter" placeholder="搜字段或值 (比如 cuda, 显存, 内存)..." />
          </div>
          <div class="appendix-grid" id="appendixGrid"></div>
        </section>
      </section>

      <aside class="right-col">
        <article class="card diag-card">
          <div class="card-header" style="margin-bottom: 14px;">
            <div>
              <div class="card-eyebrow">BOTTLENECK &amp; EXPOSURE AUDIT</div>
              <h2 class="card-title">「破绽与卡点诊断」</h2>
            </div>
          </div>

          <div class="diag-hero">
            <div class="diag-count-wrap">
              <span class="diag-big-num" id="diagBigNum">0</span>
              <span class="diag-count-text">处地方可能卡住你</span>
            </div>
            <span class="grade-badge" id="gradeBadge">评估中</span>
          </div>

          <div class="segment-wrap">
            <div class="segment-bar" id="segmentBar"></div>
            <div class="segment-labels" id="segmentLabels"></div>
          </div>

          <div class="priority-box">
            <div class="priority-header">
              <span class="priority-title">🔥 先改这几项</span>
              <span class="priority-tag" id="priorityTag">优先处理</span>
            </div>
            <ul class="priority-list" id="priorityList"></ul>
          </div>

          <div class="checklist-section-title">逐项大白话清单</div>
          <ul class="checklist" id="checklistContainer"></ul>
        </article>
      </aside>
    </main>
  </div>

  <div class="clue-popover" id="cluePopover" role="tooltip">
    <div class="pop-type" id="popType">判断依据</div>
    <div class="pop-field" id="popField"></div>
    <div class="pop-reason" id="popReason"></div>
  </div>

  <div class="modal-backdrop" id="rawModal">
    <div class="modal-box">
      <div class="modal-head">
        <span>AI_PC_Report.txt（本地只读扫描原文）</span>
        <button class="btn" id="btnCloseModal" type="button" style="padding: 4px 10px;">关闭 ✕</button>
      </div>
      <pre class="modal-pre" id="rawReportContent"></pre>
    </div>
  </div>

  <div class="toast" id="toast">已复制到剪贴板</div>

  <script>
    const SNAPSHOT = __SNAPSHOT_JSON__;
    const PREV_SNAPSHOT = __PREV_JSON__;
    const RAW_REPORT_TEXT = __RAW_REPORT_JSON__;

    function clue(type, text, field, reason) {
      const cls = type === 'red' ? 'clue clue-red' : type === 'infer' ? 'clue clue-infer' : 'clue clue-fact';
      const escField = String(field).replace(/"/g, '&quot;');
      const escReason = String(reason).replace(/"/g, '&quot;');
      return `<span class="${cls}" data-type="${type}" data-field="${escField}" data-reason="${escReason}">${text}</span>`;
    }

    function buildPortrait(s) {
      const vramGB = (s.vramTotalMiB / 1024).toFixed(0);
      const vramFreeGB = (s.vramFreeMiB / 1024).toFixed(2);
      const vramUsedGB = (s.vramUsedMiB / 1024).toFixed(2);
      const disks = s.disks || [];
      let biggestDisk = disks[0] || { Drive: 'C:', FreeGB: 0, TotalGB: 0 };
      disks.forEach(d => { if (d.FreeGB > biggestDisk.FreeGB) biggestDisk = d; });

      // P1: 归属与时空
      const p1 = `你现在用的是 ${clue('fact', s.os, 'OS: ' + s.os + ' (Build ' + s.osBuild + ')', '从系统底层读取到的 Windows 版本号。')}，面前这台机器是 ${clue('fact', s.brand + ' ' + s.model, 'Model: ' + s.brand + ' ' + s.model + ' / 主板 ' + s.board, '直接读取主板与整机型号得出的硬件身份。')}。系统里挂着 ${disks.length} 个本地分区，其中 ${clue('infer', biggestDisk.Drive + ' 盘空着 ' + biggestDisk.FreeGB + 'GB 没动', biggestDisk.Drive + ' 总计 ' + biggestDisk.TotalGB + 'GB / 空闲 ' + biggestDisk.FreeGB + 'GB', '哪个盘剩余空间最大，大模型权重和素材库就最该往哪儿放。')}，拿来囤几十个 G 的本地模型权重正合适。`;

      // P2: 破绽提醒
      const p2Parts = [];
      if (s.vramTotalMiB > 0 && s.vramTotalMiB <= 8500 && s.ramGB <= 16.5) {
        p2Parts.push(`一个是 ${clue('red', vramGB + 'GB 显存配 ' + Math.round(s.ramGB) + 'GB 内存的组合有点卡脖子', 'VRAM: ' + s.vramTotalMiB + ' MiB / RAM: ' + s.ramGB + ' GB (' + s.ramModules + ')', '显存装不下的模型得借用系统内存，16GB 内存扣掉系统自用只剩七八个 G，跑大视频模型很容易吃满卡死。')}，跑小模型挺顺，一碰要借内存的大块头就会狂刷硬盘虚拟内存`);
      } else if (s.vramTotalMiB === 0) {
        p2Parts.push(`最明显的是 ${clue('red', '机子里没检出能干活的 NVIDIA 独显', 'GPU: ' + s.gpu, '没有独显或者没装好 NVIDIA 驱动，本地跑生图和视频只能靠 CPU 硬扛。')}`);
      }
      if (s.torch.cudaAvailable !== 'True') {
        p2Parts.push(`另一个是 ${clue('red', '默认 Python 里装的是不能调显卡的 CPU 版 PyTorch', 'torch: ' + s.torch.version + ' / torch.cuda.is_available: ' + s.torch.cudaAvailable, '全局 Python 环境的 PyTorch 没带 CUDA 支持，直接运行脚本时显卡根本不会参与计算。')}`);
      }
      const p2 = p2Parts.length > 0
        ? `真要跑起本地 AI，这台电脑目前有两处容易掉链子的地方：${p2Parts.join('；')}。`
        : `从底层配置看，你的显存、内存和默认 PyTorch CUDA 环境都已经对齐，没有那种一跑脚本就报错的低级暗坑。`;

      // P3: 硬件档位口语定性
      let tierText = '中规中矩的家用办公机';
      if (s.vramTotalMiB >= 15500) tierText = '能直接硬啃大模型的重型算力机';
      else if (s.vramTotalMiB >= 7500) tierText = '算力底子不错、但被显存和内存容量框住上限的甜点机';
      else if (s.vramTotalMiB >= 4000) tierText = '适合跑轻量量化模型的入门独显机';

      const p3 = `按跑 AI 的标准来给硬件定个档，它属于 ${clue('infer', tierText, 'CPU: ' + s.cpu + ' + GPU: ' + s.gpu, '综合处理器核心数与独立显存大小给出的档位定性。')}。${clue('fact', s.cpuCores + ' 核 ' + s.cpuThreads + ' 线程的 ' + s.cpu, 'Processor: ' + s.cpu, '多核处理器负责数据加载、分词和前后处理。')} 搭上 ${clue('fact', s.gpu + '（' + vramGB + 'GB 独立显存）', 'GPU: ' + s.gpu + ' / VRAM: ' + s.vramTotalMiB + ' MiB', '决定你能装下多大模型的硬指标。')}，日常跑 7B/8B 聊天模型、SDXL 画图，或者 ${clue('infer', 'Wan 2.2 5B、FramePack 这类专门做过低显存优化的视频模型', '可用净显存约 ' + vramFreeGB + 'GB', '8GB 显存配合 GGUF Q4 量化和分块 VAE 解码，跑 5B 级视频模型刚刚好。')} 都兜得住；但别强行上未量化的原版大模型。`;

      // P4: 运行姿态点评
      const p4 = s.vramUsedMiB > 1200
        ? `再看它现在的待机姿态，${clue('red', '还没开跑就已经被后台偷走了 ' + vramUsedGB + 'GB 显存', 'VRAM Used: ' + s.vramUsedMiB + ' MiB / Free: ' + s.vramFreeMiB + ' MiB', '桌面窗口、浏览器硬件加速或模拟器占掉了近 2GB 显存，跑视频到最后一步解码时极易因为差这点显存而崩掉。')}，满打满算只留给你 ${clue('fact', vramFreeGB + 'GB 的净显存', 'memory.free: ' + s.vramFreeMiB + ' MiB', '当前真正能给 AI 模型分配的剩余独立显存。')}。而且显卡功耗上限目前停在 ${clue('fact', s.gpuPowerCap, 'Power Draw/Cap: ' + s.gpuPowerDraw + ' / ' + s.gpuPowerCap, '笔记本在平衡或安静模式下会限制显卡最高功耗。')}，跑重活前记得插紧电源、切到性能模式，并把占显存的后台软件关掉。`
        : `目前机器的待机姿态挺干净，后台只占了 ${clue('fact', vramUsedGB + 'GB 显存，留出 ' + vramFreeGB + 'GB 净空间', 'Used: ' + s.vramUsedMiB + ' MiB / Free: ' + s.vramFreeMiB + ' MiB', '后台显存占用控制得很好，大部分显存都能留给模型。')}，显卡当前功耗上限为 ${clue('fact', s.gpuPowerCap, 'Power Cap: ' + s.gpuPowerCap, '当前驱动汇报的功耗上限。')}。`;

      // P5: 偏好与开发工具链推论 + 克制声明
      const installedTools = Object.entries(s.tools).filter(([_, v]) => v && !v.includes('未')).map(([k]) => k);
      const envList = s.condaEnvs || [];
      const envText = envList.length > 0
        ? `，还在 Conda 里建了 ${clue('infer', envList.length + ' 个独立环境（' + envList.slice(0, 8).join('、') + (envList.length > 8 ? ' 等' : '') + '）', 'Conda Envs: ' + envList.join(', '), '每个虚拟环境对应一个折腾过的项目，从名字就能看出平时在跑哪些业务。')}`
        : '';
      const p5 = `翻一下装好的工具链就知道你平时没少折腾代码：机子里能直接调起 ${clue('fact', installedTools.join('、'), 'Detected CLI Tools in PATH', '这些开发工具全部在终端 PATH 中可直接调用。')}${envText}。至于你的真实姓名、年龄和长相，本地硬件脚本读不出来，这里也不瞎猜。`;

      // P6: 当前访问时段与温度状态
      const p6 = `这次扫描发生在 ${clue('fact', s.timeInfo.cnDay + s.timeInfo.timePeriod + '（' + s.timestamp + '）', 'Timestamp: ' + s.timestamp, '本次运行检测脚本的本地时间。')}，显卡核心温度 ${clue('fact', s.gpuTemp + '，当前功耗 ' + s.gpuPowerDraw, 'Temp: ' + s.gpuTemp + ' / Power: ' + s.gpuPowerDraw + ' / State: ' + s.gpuPerfState, 'nvidia-smi 实时读取到的显卡传感器状态。')}，风扇还没怎么转，正处于随时能拉起来干活的轻载状态。`;

      // P7: 指纹辨识度与最显眼维度
      const p7 = `综合算下来，这台电脑的本地特征辨识度很高。最显眼的地方有三处：${clue('fact', s.cpu + ' 搭 ' + s.gpu + ' 的硬件底子', 'CPU + GPU Combo', '核心算力组合。')}、${clue('fact', biggestDisk.Drive + ' 盘那 ' + biggestDisk.FreeGB + 'GB 的空闲空间', 'Max Free Disk: ' + biggestDisk.Drive, '模型存储主力分区。')}，以及 ${s.ramGB <= 16.5 ? clue('red', '目前最值得花点小钱升到 32GB 以上的 ' + s.ramModules + ' 内存', 'RAM: ' + s.ramModules, '把 16GB 内存升到 32GB 或 64GB，是这台笔记本提升大模型兼容性性价比最高的一步。') : clue('fact', s.ramModules + ' 的充裕内存配置', 'RAM: ' + s.ramModules, '内存容量充足，支持模型分块卸载。')}。`;

      return [p1, p2, p3, p4, p5, p6, p7];
    }

    function buildDiagnosis(s) {
      const issues = [];
      const goods = [];
      const topFixes = [];

      if (s.torch.cudaAvailable !== 'True') {
        issues.push({ level: 'red', title: '默认 Python 的 PyTorch 调不到显卡', note: '当前全局环境装的是 CPU 版 PyTorch（或没装），直接跑脚本会让显卡闲置、CPU 硬扛。' });
        topFixes.push({
          head: '给默认 Python 换上带 CUDA 的 PyTorch',
          desc: '你的驱动最高支持到 CUDA ' + s.cudaMax + '，重装带 cu126 的 PyTorch 就能直接调起显卡：',
          cmd: 'pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu126 --force-reinstall'
        });
      } else {
        goods.push({ level: 'green', title: '默认 PyTorch 已打通显卡 CUDA', note: '全局 Python 可直接调用 ' + s.gpu + ' 加速。' });
      }

      if (s.ramGB <= 16.5 && s.vramTotalMiB <= 8500) {
        issues.push({ level: 'red', title: '16GB 内存兜不住大模型的内存卸载', note: '8GB 显存跑生图或视频模型经常要借用系统内存，16GB 物理内存扣掉系统自用只剩七八个 G，借多了就会狂读硬盘卡死。' });
        topFixes.push({
          head: '把内存条从 16GB 升到 32GB 或 64GB',
          desc: '笔记本显存焊死改不了，但换两根 16G/32G 内存条就能打通 FLUX 和 14B 视频模型的 CPU 卸载通道。',
          cmd: ''
        });
      } else {
        goods.push({ level: 'green', title: '系统内存容量充裕 (' + s.ramGB + 'GB)', note: '足够支撑大模型权重的 CPU 内存卸载（Block Swap）。' });
      }

      if (s.vramUsedMiB > 1400) {
        issues.push({ level: 'amber', title: '桌面后台吃掉了 ' + (s.vramUsedMiB / 1024).toFixed(2) + 'GB 独立显存', note: '总共 ' + s.vramTotalMiB + ' MiB 显存现在只剩 ' + s.vramFreeMiB + ' MiB，跑视频到最后一步 VAE 解码时最容易差这一口气。' });
        topFixes.push({
          head: '跑大模型前清掉后台显存大户并切到高性能模式',
          desc: '关掉安卓模拟器、多余浏览器网页的硬件加速，并在电脑控制中心切到狂暴/高性能模式解锁功耗墙。',
          cmd: ''
        });
      }

      const capNum = parseInt(String(s.gpuPowerCap).replace(/[^\d]/g, ''), 10);
      if (capNum > 0 && capNum <= 85) {
        issues.push({ level: 'amber', title: '显卡功耗上限目前锁在 ' + s.gpuPowerCap, note: '处于偏保守的功耗档位，长时间跑视频生成建议插电并在自带控制中心切到性能/狂暴模式。' });
      }

      if (String(s.tools.nvcc).includes('未安装')) {
        issues.push({ level: 'amber', title: '没装系统级 nvcc 编译器（日常使用不用管）', note: '驱动已支持 CUDA ' + s.cudaMax + '，平时跑现成模型完全够用；只有自己从源码编译 FlashAttention 算子时才需要装 CUDA Toolkit。' });
      }

      if (!String(s.tools.conda).includes('未') && !String(s.tools.code).includes('未')) {
        goods.push({ level: 'green', title: '终端 PATH 与开发工具链已就绪', note: s.tools.conda + '、VS Code (' + s.tools.code + ')、Git 等均可在终端直接调用。' });
      }

      const disks = s.disks || [];
      let biggestDisk = disks[0] || { Drive: 'C:', FreeGB: 0 };
      disks.forEach(d => { if (d.FreeGB > biggestDisk.FreeGB) biggestDisk = d; });
      if (biggestDisk.FreeGB >= 150) {
        goods.push({ level: 'green', title: biggestDisk.Drive + ' 盘还有 ' + biggestDisk.FreeGB + 'GB 空闲空间', note: '足够放下多套生图与视频生成大模型。' });
      }

      return { issues, goods, topFixes };
    }

    // Render Page
    document.getElementById('metaTimestamp').textContent = '采样时间：' + SNAPSHOT.timestamp;
    document.getElementById('fpHashText').textContent = SNAPSHOT.fingerprintId;
    document.getElementById('fpSubText').textContent = `实测核心：${SNAPSHOT.cpu} · ${SNAPSHOT.gpu} (${Math.round(SNAPSHOT.vramTotalMiB/1024)}GB) · 内存 ${Math.round(SNAPSHOT.ramGB)}GB`;

    const paragraphs = buildPortrait(SNAPSHOT);
    const narrativeContainer = document.getElementById('narrativeContainer');
    paragraphs.forEach((html, idx) => {
      const p = document.createElement('p');
      p.className = 'narrative-p';
      const num = String(idx + 1).padStart(2, '0');
      p.innerHTML = `<span class="p-index">${num}</span>${html}`;
      narrativeContainer.appendChild(p);
    });

    // Diff against previous snapshot
    const diffList = document.getElementById('diffList');
    const diffBadge = document.getElementById('diffBadge');
    if (PREV_SNAPSHOT && PREV_SNAPSHOT.timestamp) {
      const diffs = [];
      const vramDiff = SNAPSHOT.vramFreeMiB - (PREV_SNAPSHOT.vramFreeMiB || 0);
      if (Math.abs(vramDiff) >= 30) {
        diffs.push(`可用显存 ${vramDiff > 0 ? '增加了 ' + vramDiff : '减少了 ' + Math.abs(vramDiff)} MiB（当前 ${SNAPSHOT.vramFreeMiB} MiB）`);
      }
      if (SNAPSHOT.tools.conda !== PREV_SNAPSHOT.tools?.conda) {
        diffs.push(`Conda 状态更新为：${SNAPSHOT.tools.conda}`);
      }
      if (SNAPSHOT.tools.code !== PREV_SNAPSHOT.tools?.code) {
        diffs.push(`VS Code CLI 状态更新为：${SNAPSHOT.tools.code}`);
      }
      if (SNAPSHOT.torch.cudaAvailable !== PREV_SNAPSHOT.torch?.cudaAvailable) {
        diffs.push(`全局 PyTorch CUDA 可用性变为：${SNAPSHOT.torch.cudaAvailable}`);
      }
      if (diffs.length === 0) {
        diffs.push(`核心硬件与工具链状态与上次（${PREV_SNAPSHOT.timestamp.split(' ')[1]}）一致`);
        diffBadge.textContent = '状态稳定';
      } else {
        diffBadge.textContent = `${diffs.length} 处变化`;
      }
      diffs.forEach(d => {
        const li = document.createElement('li');
        li.innerHTML = `<span class="diff-plus">~</span><span>${d}</span>`;
        diffList.appendChild(li);
      });
    } else {
      diffBadge.textContent = '基准已建立';
      const li = document.createElement('li');
      li.innerHTML = `<span class="diff-plus">+</span><span>已保存本次扫描快照，下次双击运行会自动对比变化</span>`;
      diffList.appendChild(li);
    }

    // Diagnosis rendering
    const diag = buildDiagnosis(SNAPSHOT);
    const redCount = diag.issues.filter(i => i.level === 'red').length;
    const amberCount = diag.issues.filter(i => i.level === 'amber').length;
    const greenCount = diag.goods.length;

    document.getElementById('diagBigNum').textContent = diag.issues.length;
    document.getElementById('gradeBadge').textContent = redCount === 0 ? 'A 满血就绪级' : redCount <= 2 ? 'B+ 甜点受限级' : 'C 亟待排障级';

    const segBar = document.getElementById('segmentBar');
    segBar.innerHTML = `
      <div class="seg-red" style="flex:${Math.max(1, redCount)}"></div>
      <div class="seg-amber" style="flex:${Math.max(1, amberCount)}"></div>
      <div class="seg-green" style="flex:${Math.max(2, greenCount)}"></div>
    `;
    document.getElementById('segmentLabels').innerHTML = `
      <span>🔴 ${redCount} 处立刻卡脖子</span>
      <span>🟡 ${amberCount} 处跑大模型受限</span>
      <span>🟢 ${greenCount} 项健康就绪</span>
    `;

    const priorityList = document.getElementById('priorityList');
    document.getElementById('priorityTag').textContent = `TOP ${diag.topFixes.length}`;
    diag.topFixes.forEach((f, i) => {
      const li = document.createElement('li');
      li.className = 'priority-item';
      const cmdHtml = f.cmd ? '<div class="priority-cmd">' + f.cmd + '</div>' : '';
      li.innerHTML = '<div class="priority-item-head">' + (i + 1) + '. ' + f.head + '</div><div class="priority-item-desc">' + f.desc + '</div>' + cmdHtml;
      priorityList.appendChild(li);
    });

    const checklistContainer = document.getElementById('checklistContainer');
    [...diag.issues, ...diag.goods].forEach(item => {
      const li = document.createElement('li');
      li.className = 'check-item';
      const dotCls = item.level === 'red' ? 'dot-red' : item.level === 'amber' ? 'dot-amber' : 'dot-green';
      li.innerHTML = `
        <span class="check-dot ${dotCls}"></span>
        <div class="check-content">
          <div class="check-title">${item.title}</div>
          <div class="check-note">${item.note}</div>
        </div>
      `;
      checklistContainer.appendChild(li);
    });

    // Technical Appendix
    const appendixItems = [
      { k: "电脑品牌与型号", v: `${SNAPSHOT.brand} ${SNAPSHOT.model}`, status: "" },
      { k: "主板与 BIOS", v: `${SNAPSHOT.board} / BIOS ${SNAPSHOT.bios}`, status: "" },
      { k: "操作系统", v: `${SNAPSHOT.os} (Build ${SNAPSHOT.osBuild})`, status: "" },
      { k: "处理器 (CPU)", v: `${SNAPSHOT.cpu} (${SNAPSHOT.cpuCores}C/${SNAPSHOT.cpuThreads}T)`, status: "ok" },
      { k: "物理内存总量", v: `${SNAPSHOT.ramGB} GB (${SNAPSHOT.ramModules})`, status: SNAPSHOT.ramGB <= 16.5 ? "warn" : "ok" },
      { k: "独立显卡 (GPU)", v: SNAPSHOT.gpu, status: "ok" },
      { k: "专用显存 (VRAM)", v: `总计 ${SNAPSHOT.vramTotalMiB} MiB / 已用 ${SNAPSHOT.vramUsedMiB} MiB / 空闲 ${SNAPSHOT.vramFreeMiB} MiB`, status: SNAPSHOT.vramFreeMiB < 6500 ? "warn" : "ok" },
      { k: "NVIDIA 驱动与最高 CUDA", v: `Driver ${SNAPSHOT.nvDriver} / CUDA ${SNAPSHOT.cudaMax}`, status: "ok" },
      { k: "显卡功耗与温度", v: `${SNAPSHOT.gpuPowerDraw} / ${SNAPSHOT.gpuPowerCap} | ${SNAPSHOT.gpuTemp} (${SNAPSHOT.gpuPerfState})`, status: "" },
      ...SNAPSHOT.disks.map(d => ({ k: `磁盘 ${d.Drive} 容量`, v: `总计 ${d.TotalGB} GB / 空闲 ${d.FreeGB} GB`, status: d.FreeGB > 200 ? "ok" : d.FreeGB < 50 ? "warn" : "" })),
      { k: "全局 Python", v: SNAPSHOT.tools.python, status: "ok" },
      { k: "全局 PyTorch 版本", v: `${SNAPSHOT.torch.version} (CUDA Runtime: ${SNAPSHOT.torch.cudaRuntime})`, status: SNAPSHOT.torch.cudaAvailable === 'True' ? "ok" : "warn" },
      { k: "全局 torch.cuda.is_available", v: SNAPSHOT.torch.cudaAvailable, status: SNAPSHOT.torch.cudaAvailable === 'True' ? "ok" : "warn" },
      { k: "Conda 状态与环境数", v: `${SNAPSHOT.tools.conda} (${SNAPSHOT.condaEnvs.length} 个自定义环境)`, status: "ok" },
      { k: "Conda 环境列表", v: SNAPSHOT.condaEnvs.join(', ') || '无', status: "" },
      { k: "uv / Git", v: `${SNAPSHOT.tools.uv} / ${SNAPSHOT.tools.git}`, status: "ok" },
      { k: "Node.js / pnpm", v: `${SNAPSHOT.tools.node} / pnpm ${SNAPSHOT.tools.pnpm}`, status: "ok" },
      { k: "VS Code CLI (code)", v: SNAPSHOT.tools.code, status: "ok" },
      { k: "Rust / .NET / Docker", v: `${SNAPSHOT.tools.rust} | .NET ${SNAPSHOT.tools.dotnet} | ${SNAPSHOT.tools.docker}`, status: "" },
      { k: "FFmpeg / nvcc", v: `FFmpeg: ${SNAPSHOT.tools.ffmpeg} | nvcc: ${SNAPSHOT.tools.nvcc}`, status: "" }
    ];

    document.getElementById('appendixTitle').textContent = `全部探测项和读到的值（底层技术附录 · 共 ${appendixItems.length} 项）`;
    const appendixGrid = document.getElementById('appendixGrid');
    function renderAppendix(q = '') {
      const kw = q.trim().toLowerCase();
      appendixGrid.innerHTML = '';
      appendixItems.forEach(item => {
        if (kw && !item.k.toLowerCase().includes(kw) && !String(item.v).toLowerCase().includes(kw)) return;
        const row = document.createElement('div');
        row.className = 'kv-row';
        const cls = item.status === 'warn' ? 'kv-val val-warn' : item.status === 'ok' ? 'kv-val val-ok' : 'kv-val';
        row.innerHTML = `<span class="kv-key">${item.k}</span><span class="${cls}">${item.v}</span>`;
        appendixGrid.appendChild(row);
      });
    }
    renderAppendix();
    document.getElementById('appendixSearch').addEventListener('input', e => renderAppendix(e.target.value));

    // Popover interactions
    const popover = document.getElementById('cluePopover');
    const popType = document.getElementById('popType');
    const popField = document.getElementById('popField');
    const popReason = document.getElementById('popReason');
    let pinnedClue = null;

    const TYPE_MAP = {
      red: { text: '🔴 会卡住你的短板', cls: 'pop-type type-red' },
      fact: { text: '⚪ 机子实测数据', cls: 'pop-type type-fact' },
      infer: { text: '🟢 使用习惯侧写依据', cls: 'pop-type type-infer' }
    };

    function showPopover(target) {
      const t = target.getAttribute('data-type') || 'fact';
      const cfg = TYPE_MAP[t] || TYPE_MAP.fact;
      popType.className = cfg.cls;
      popType.innerHTML = `<span>${cfg.text}</span><span style="font-weight:400;opacity:0.7;">${pinnedClue === target ? '已固定' : '点按可固定'}</span>`;
      popField.textContent = target.getAttribute('data-field') || '';
      popReason.textContent = target.getAttribute('data-reason') || '';
      popover.classList.add('visible');

      const rect = target.getBoundingClientRect();
      const popWidth = 340;
      let left = Math.max(12, Math.min(rect.left + rect.width / 2 - popWidth / 2, window.innerWidth - popWidth - 12));
      let top = rect.bottom + 10;
      const popHeight = popover.offsetHeight || 120;
      if (top + popHeight > window.innerHeight - 12) top = rect.top - popHeight - 10;
      popover.style.left = left + 'px';
      popover.style.top = Math.max(12, top) + 'px';
    }

    document.querySelectorAll('.clue').forEach(el => {
      el.addEventListener('mouseenter', () => { if (!pinnedClue) showPopover(el); });
      el.addEventListener('mouseleave', () => { if (!pinnedClue) popover.classList.remove('visible'); });
      el.addEventListener('click', e => {
        e.stopPropagation();
        if (pinnedClue === el) {
          el.classList.remove('active');
          pinnedClue = null;
          popover.classList.remove('visible');
        } else {
          if (pinnedClue) pinnedClue.classList.remove('active');
          pinnedClue = el;
          el.classList.add('active');
          showPopover(el);
        }
      });
    });
    document.addEventListener('click', () => {
      if (pinnedClue) {
        pinnedClue.classList.remove('active');
        pinnedClue = null;
        popover.classList.remove('visible');
      }
    });

    // Toast & Buttons
    const toast = document.getElementById('toast');
    let toastTimer = null;
    function showToast(msg) {
      toast.textContent = msg;
      toast.classList.add('show');
      clearTimeout(toastTimer);
      toastTimer = setTimeout(() => toast.classList.remove('show'), 2400);
    }

    document.getElementById('btnCopyPortrait').addEventListener('click', () => {
      const text = Array.from(document.querySelectorAll('.narrative-p')).map(p => p.innerText.replace(/\s+/g, ' ').trim()).join('\n\n');
      navigator.clipboard.writeText(`【寻祎居 · AI 眼里的这台电脑 (${SNAPSHOT.fingerprintId})】\n\n${text}`).then(() => showToast('✅ 已复制 7 段侧写'));
    });

    document.getElementById('btnCopyJson').addEventListener('click', () => {
      navigator.clipboard.writeText(JSON.stringify(SNAPSHOT, null, 2)).then(() => showToast('🧬 已复制 JSON 快照'));
    });

    let expanded = false;
    document.getElementById('btnToggleClues').addEventListener('click', e => {
      expanded = !expanded;
      document.querySelectorAll('.narrative-p').forEach(p => {
        const old = p.querySelector('.inline-clues-dump');
        if (old) old.remove();
        if (expanded) {
          const dump = document.createElement('div');
          dump.className = 'inline-clues-dump';
          dump.style.cssText = 'margin-top:8px;padding-top:8px;border-top:1px dashed rgba(255,255,255,0.08);font-size:12px;color:#9ba3b2;display:flex;flex-direction:column;gap:4px;';
          p.querySelectorAll('.clue').forEach(c => {
            const d = document.createElement('div');
            d.innerHTML = `<code style="color:#38bdf8;">[${c.getAttribute('data-field')}]</code> → ${c.getAttribute('data-reason')}`;
            dump.appendChild(d);
          });
          p.appendChild(dump);
        }
      });
      e.currentTarget.textContent = expanded ? '🔼 收起所有判断依据' : '💡 展开所有判断依据';
    });

    const rawModal = document.getElementById('rawModal');
    document.getElementById('rawReportContent').textContent = RAW_REPORT_TEXT;
    document.getElementById('btnViewRaw').addEventListener('click', () => rawModal.classList.add('open'));
    document.getElementById('btnCloseModal').addEventListener('click', () => rawModal.classList.remove('open'));
    rawModal.addEventListener('click', e => { if (e.target === rawModal) rawModal.classList.remove('open'); });

    document.getElementById('btnCopyCmd').addEventListener('click', () => {
      navigator.clipboard.writeText('powershell -NoProfile -ExecutionPolicy Bypass -File .\\AI_PC_Environment_Audit.ps1').then(() => showToast('⚡ 已复制重测命令'));
    });
  </script>
</body>
</html>
'@

$finalHtml = $htmlTemplate.Replace('__SNAPSHOT_JSON__', $snapshotJsonStr).Replace('__PREV_JSON__', $prevJsonStr).Replace('__RAW_REPORT_JSON__', $rawReportEscaped)
$finalHtml | Set-Content -LiteralPath $htmlPath -Encoding UTF8

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host " 扫描完成！" -ForegroundColor Green
Write-Host " 1. 可视化侧写网页 : $htmlPath" -ForegroundColor Green
Write-Host " 2. 原始文本报告   : $reportPath" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green

if (-not $NoOpenBrowser) {
    try { Start-Process $htmlPath } catch {}
}
