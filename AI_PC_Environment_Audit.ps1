# AI PC Environment Audit & Portrait Generator (寻祎居 · 算力底牌侧写 / XunyiJu AI PC Audit)
# Read-only by default. Optional interactive domestic-mirror runtime installer when missing dependencies are detected.
[CmdletBinding()]
param(
    [ValidateSet('zh', 'en', '')]
    [string]$Language = '',
    [switch]$IncludeSoftwareList,
    [switch]$NoOpenBrowser,
    [switch]$SkipRuntimePrompt,
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$auditStartTime = Get-Date
$auditStartStr  = $auditStartTime.ToString('yyyy-MM-dd HH:mm:ss.fff zzz')
$auditStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$stageTimings   = New-Object 'System.Collections.Generic.List[object]'

$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $scriptDir 'AI_PC_Audit_Result'
}

# ==============================================================================
# 0. 语言选择与内置语言/运行环境自检 (Language Selection & Built-in Runtime Check)
# ==============================================================================
$installedOscultures = @()
try {
    if (Get-Command Get-WinUserLanguageList -ErrorAction SilentlyContinue) {
        $installedOscultures = @(Get-WinUserLanguageList | ForEach-Object { $_.LanguageTag })
    }
} catch {}
if ($installedOscultures.Count -eq 0) {
    $installedOscultures = @([System.Globalization.CultureInfo]::InstalledUICulture.Name, [System.Globalization.CultureInfo]::CurrentUICulture.Name) | Select-Object -Unique
}
$hasZhPack = ($installedOscultures -match '^zh') -or ([System.Globalization.CultureInfo]::InstalledUICulture.Name -match '^zh')
$hasEnPack = ($installedOscultures -match '^en') -or $true # ASCII/English is natively supported on all Windows consoles

$hasPwsh7  = [bool](Get-Command pwsh -ErrorAction SilentlyContinue)
$runningPsMajor = $PSVersionTable.PSVersion.Major
$hasPython = [bool](Get-Command python -ErrorAction SilentlyContinue)
$hasPip    = [bool](Get-Command pip -ErrorAction SilentlyContinue)
$hasNvidiaSmi = [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue)

# Quick pre-check of PyTorch CUDA status in default Python (distinguishing CUDA build support vs runtime availability)
$prePyPath         = 'Not Found'
$preTorchInstalled = $false
$preTorchCudaBuilt = $false
$preTorchCudaRt    = 'None'
$preTorchCudaOk    = $false
$preTorchVer       = 'Not Installed'
if ($hasPython) {
    try {
        $preOut = & python -c "import sys; print('EXEC=' + sys.executable); import torch; print('VER=' + str(torch.__version__)); print('RT=' + str(torch.version.cuda)); print('OK=' + str(torch.cuda.is_available()))" 2>$null
        if ($preOut) {
            foreach ($line in ($preOut -split "`r?`n")) {
                if ($line -match '^EXEC=(.+)$') {
                    $p = $Matches[1].Trim()
                    if ($env:USERPROFILE) { $p = $p.Replace($env:USERPROFILE, '%USERPROFILE%') }
                    $prePyPath = $p
                }
                if ($line -match '^VER=(.+)$') { $preTorchInstalled = $true; $preTorchVer = $Matches[1].Trim() }
                if ($line -match '^RT=(.+)$')  { $preTorchCudaRt = $Matches[1].Trim(); $preTorchCudaBuilt = ($preTorchCudaRt -ne 'None' -and $preTorchCudaRt -ne '') }
                if ($line -match '^OK=(.+)$')  { $preTorchCudaOk = ($Matches[1].Trim() -eq 'True') }
            }
        }
    } catch {}
}

if ([string]::IsNullOrWhiteSpace($Language)) {
    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "  寻祎居 · 算力底牌侧写 | XunyiJu · AI PC Capability Audit" -ForegroundColor Cyan
    Write-Host "  终端引擎 / Shell: PowerShell $($PSVersionTable.PSVersion) (PID: $PID)" -ForegroundColor DarkCyan
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "  [内置语言与运行环境预检 / Built-in Language & Runtime Pre-check]" -ForegroundColor Yellow
    Write-Host ("    - 简体中文语言支持 (zh-CN) : " + ($(if ($hasZhPack) { "已内置 / Ready" } else { "未检出中文语言包 / Missing zh-CN pack" }))) -ForegroundColor ($(if ($hasZhPack) { "Green" } else { "Red" }))
    Write-Host ("    - 英文语言支持 (en-US)     : 已内置 / Ready") -ForegroundColor Green
    Write-Host ("    - PowerShell 7+ (pwsh)     : " + ($(if ($hasPwsh7) { "已安装 / Installed (当前 v$($PSVersionTable.PSVersion))" } else { "未安装 (当前为旧版 PS $($PSVersionTable.PSVersion))" }))) -ForegroundColor ($(if ($hasPwsh7) { "Green" } else { "Yellow" }))
    Write-Host ("    - 实际检测的默认 Python    : " + ($(if ($hasPython) { "$prePyPath (注: ComfyUI/Conda 可能使用独立环境)" } else { "未安装 / Missing (无法深度检测 AI 库)" }))) -ForegroundColor ($(if ($hasPython) { "Green" } else { "Red" }))
    $torchStatusStr = if (-not $preTorchInstalled) {
        "未在此默认 Python 中安装 PyTorch"
    } elseif ($preTorchCudaBuilt -and $preTorchCudaOk) {
        "支持 CUDA ($preTorchCudaRt) 且当前可用 ($preTorchVer)"
    } elseif ($preTorchCudaBuilt -and (-not $preTorchCudaOk)) {
        "已装支持 CUDA ($preTorchCudaRt) 的版本 ($preTorchVer)，但当前无法调起显卡 (无需重装 PyTorch，请查驱动)"
    } else {
        "纯 CPU 构建版 ($preTorchVer，不支持 CUDA)"
    }
    Write-Host ("    - 默认 Python PyTorch 状态 : " + $torchStatusStr) -ForegroundColor ($(if ($preTorchCudaOk) { "Green" } else { "Yellow" }))
    Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  请选择界面与报告语言 / Please select language:" -ForegroundColor Yellow
    Write-Host "    [1] 简体中文 (Simplified Chinese)  [默认 / Default]" -ForegroundColor White
    Write-Host "    [2] English" -ForegroundColor White
    Write-Host ""
    try {
        $choice = Read-Host "  输入序号并回车 / Enter 1 or 2 (Press Enter for 简体中文)"
        if ($choice -match '^(2|en|eng|english)$') {
            $Language = 'en'
        } else {
            $Language = 'zh'
        }
    } catch {
        $Language = 'zh'
    }
}

$isEn = ($Language -eq 'en')

# ==============================================================================
# 0.5 缺失内置语言或基础解释器时，提示是否通过国内镜像补齐（默认绝不提示强制重装 PyTorch）
# ==============================================================================
$missingItems = New-Object 'System.Collections.Generic.List[hashtable]'

if ($Language -eq 'zh' -and -not $hasZhPack) {
    $missingItems.Add(@{
        Id = 'zh_pack'
        NameZh = 'Windows 简体中文内置显示语言包 (zh-CN)'
        NameEn = 'Windows Simplified Chinese Language Pack (zh-CN)'
        DescZh = '当前系统缺少 zh-CN 语言包，终端或部分中文字符可能显示异常。'
        DescEn = 'System is missing the zh-CN language pack; Chinese characters in console may not render properly.'
    })
}
if (-not $hasPython) {
    $missingItems.Add(@{
        Id = 'python'
        NameZh = 'Python 3.11 运行语言环境（华为云/阿里国内镜像）'
        NameEn = 'Python 3.11 Runtime (via Huawei/Aliyun China Mirror)'
        DescZh = '未检测到内置或全局 Python，脚本无法进一步探测 PyTorch、CUDA、Transformers 等 AI 依赖库。'
        DescEn = 'Python is not found in PATH; the script cannot probe PyTorch, CUDA, or AI libraries without it.'
    })
}
if (-not $hasPwsh7) {
    $missingItems.Add(@{
        Id = 'pwsh7'
        NameZh = 'PowerShell 7 现代终端引擎（国内镜像优先）'
        NameEn = 'PowerShell 7 Modern Shell (Domestic Mirror Priority)'
        DescZh = '当前正在使用 Windows 旧版 PowerShell 5.1，建议升级至 PowerShell 7 以避免 UTF-8 编码问题。'
        DescEn = 'Currently running on legacy Windows PowerShell 5.1; PowerShell 7 is recommended for full UTF-8 support.'
    })
}

if ($missingItems.Count -gt 0 -and (-not $SkipRuntimePrompt)) {
    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Yellow
    if ($isEn) {
        Write-Host "  [Notice] Some built-in languages or AI runtime components are missing/incomplete:" -ForegroundColor Yellow
    } else {
        Write-Host "  [提示] 检测到以下内置语言或 AI 运行环境缺失/未打通（可优先使用国内镜像补齐）：" -ForegroundColor Yellow
    }
    Write-Host "==================================================================" -ForegroundColor Yellow

    for ($i = 0; $i -lt $missingItems.Count; $i++) {
        $item = $missingItems[$i]
        $idx = $i + 1
        if ($isEn) {
            Write-Host "  [$idx] $($item.NameEn)" -ForegroundColor White
            Write-Host "      Reason: $($item.DescEn)" -ForegroundColor Gray
        } else {
            Write-Host "  [$idx] $($item.NameZh)" -ForegroundColor White
            Write-Host "      说明：  $($item.DescZh)" -ForegroundColor Gray
        }
    }
    Write-Host ""
    if ($isEn) {
        Write-Host "  Options: Enter item number(s) (e.g. 1 or 1,2) to download/fix via China Domestic Mirrors," -ForegroundColor Cyan
        Write-Host "           or press [Enter / N] to skip and continue read-only scan immediately." -ForegroundColor Cyan
    } else {
        Write-Host "  操作选择：输入对应序号（如 1 或 1,2）立即通过【国内镜像】下载/修复，" -ForegroundColor Cyan
        Write-Host "            直接按【回车 / N】则跳过安装，立即继续只读体检。" -ForegroundColor Cyan
    }

    try {
        $fixChoice = Read-Host "  请选择 / Your choice (Enter = 跳过/Skip)"
        if (-not [string]::IsNullOrWhiteSpace($fixChoice) -and ($fixChoice -notmatch '^(n|no|s|skip|0)$')) {
            $selectedIndices = @()
            if ($fixChoice -match '^(y|yes|all|a)$') {
                $selectedIndices = 1..($missingItems.Count)
            } else {
                foreach ($token in ($fixChoice -split '[,\s]+')) {
                    if ($token -match '^\d+$') {
                        $num = [int]$token
                        if ($num -ge 1 -and $num -le $missingItems.Count) {
                            $selectedIndices += $num
                        }
                    }
                }
            }

            foreach ($sel in $selectedIndices) {
                $target = $missingItems[$sel - 1]
                switch ($target.Id) {
                    'zh_pack' {
                        Write-Host "  -> 正在调用 Windows 语言包组件安装 zh-CN..." -ForegroundColor Cyan
                        try {
                            if (Get-Command Install-Language -ErrorAction SilentlyContinue) {
                                Install-Language -Language zh-CN -ErrorAction Stop
                                Write-Host "  [OK] zh-CN 语言包安装完成。" -ForegroundColor Green
                            } else {
                                Start-Process "ms-settings:regionlanguage"
                            }
                        } catch {
                            Write-Host "  [!] 需要管理员权限安装系统语言包，已为您打开系统语言设置页。" -ForegroundColor Yellow
                            try { Start-Process "ms-settings:regionlanguage" } catch {}
                        }
                    }
                    'python' {
                        $pyInstallerUrl = "https://mirrors.huaweicloud.com/python/3.11.9/python-3.11.9-amd64.exe"
                        $pyInstallerPath = Join-Path $env:TEMP "python-3.11.9-amd64.exe"
                        Write-Host "  -> 正在从华为云国内镜像下载 Python 3.11.9: $pyInstallerUrl ..." -ForegroundColor Cyan
                        try {
                            Invoke-WebRequest -Uri $pyInstallerUrl -OutFile $pyInstallerPath -UseBasicParsing
                            Write-Host "  -> 正在安装 Python 3.11.9（自动加入 PATH）..." -ForegroundColor Cyan
                            Start-Process -FilePath $pyInstallerPath -ArgumentList "/passive InstallAllUsers=0 PrependPath=1 Include_test=0" -Wait
                            $env:Path = [Environment]::GetEnvironmentVariable("Path", "User") + ";" + [Environment]::GetEnvironmentVariable("Path", "Machine")
                            Write-Host "  [OK] Python 3.11.9 安装完成。" -ForegroundColor Green
                        } catch {
                            Write-Host "  [!] 下载或安装失败: $($_.Exception.Message)" -ForegroundColor Red
                        }
                    }
                    'pwsh7' {
                        Write-Host "  -> 正在通过 WinGet / 国内镜像安装 PowerShell 7..." -ForegroundColor Cyan
                        try {
                            if (Get-Command winget -ErrorAction SilentlyContinue) {
                                & winget install --id Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements
                            } else {
                                Write-Host "  [!] 未找到 winget，请访问 https://mirror.ghproxy.com/https://github.com/PowerShell/PowerShell/releases 下载 MSI。" -ForegroundColor Yellow
                            }
                        } catch {
                            Write-Host "  [!] PowerShell 7 安装异常: $($_.Exception.Message)" -ForegroundColor Red
                        }
                    }
                    'pytorch_cuda' {
                        Write-Host "  -> 正在通过【南京大学 PyTorch CUDA 国内镜像 + 清华 TUNA 源】重装带 CUDA (cu126) 的 PyTorch..." -ForegroundColor Cyan
                        Write-Host "     执行命令: pip install torch torchvision torchaudio -i https://mirror.nju.edu.cn/pytorch/whl/cu126 --extra-index-url https://pypi.tuna.tsinghua.edu.cn/simple --force-reinstall" -ForegroundColor DarkCyan
                        try {
                            & python -m pip install torch torchvision torchaudio -i https://mirror.nju.edu.cn/pytorch/whl/cu126 --extra-index-url https://pypi.tuna.tsinghua.edu.cn/simple --force-reinstall
                            Write-Host "  [OK] PyTorch CUDA 国内镜像安装完成！" -ForegroundColor Green
                        } catch {
                            Write-Host "  [!] PyTorch CUDA 安装异常: $($_.Exception.Message)" -ForegroundColor Red
                        }
                    }
                }
            }
        }
    } catch {}
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$reportPath   = Join-Path $OutputDirectory 'AI_PC_Report.txt'
$htmlPath     = Join-Path $OutputDirectory 'index.html'
$jsonPath     = Join-Path $OutputDirectory 'AI_PC_Snapshot.json'
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

# ==============================================================================
# Stage 1: Hardware, Disk, OS
# ==============================================================================
$swStage = [System.Diagnostics.Stopwatch]::StartNew()
$stage1At = (Get-Date).ToString('HH:mm:ss.fff')
Write-Host ""
if ($isEn) {
    Write-Host "[1/4] ($stage1At) Collecting hardware, disk, and OS information..." -ForegroundColor Cyan
} else {
    Write-Host "[1/4] ($stage1At) 正在采集电脑硬件、磁盘与操作系统信息..." -ForegroundColor Cyan
}

$hourNow = (Get-Date).Hour
$dayNameEn = (Get-Date).DayOfWeek.ToString()
$dayOfWeekMap = @{ 'Monday'='周一'; 'Tuesday'='周二'; 'Wednesday'='周三'; 'Thursday'='周四'; 'Friday'='周五'; 'Saturday'='周六'; 'Sunday'='周日' }
$cnDay = $dayOfWeekMap[$dayNameEn]
$timePeriod = if ($hourNow -lt 6) { '凌晨' } elseif ($hourNow -lt 12) { '上午' } elseif ($hourNow -lt 14) { '中午' } elseif ($hourNow -lt 18) { '下午' } else { '晚上' }
$timePeriodEn = if ($hourNow -lt 6) { 'early morning' } elseif ($hourNow -lt 12) { 'morning' } elseif ($hourNow -lt 14) { 'noon' } elseif ($hourNow -lt 18) { 'afternoon' } else { 'evening' }

$cs   = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$os   = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$bb   = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue
$bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
$cpu  = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
$rams = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
$gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
$disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)

$brand = if ($cs.Manufacturer) { $cs.Manufacturer.Trim() } else { 'Unknown Brand' }
$model = if ($cs.Model) { $cs.Model.Trim() } else { 'Generic PC' }
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
    "$($rams.Count)x ${stickGB}GB ($stickMaker ${stickSpeed}MHz)"
} else {
    "${ramGB} GB"
}

$diskList = @()
foreach ($d in $disks) {
    $tGB = [math]::Round($d.Size / 1GB, 1)
    $fGB = [math]::Round($d.FreeSpace / 1GB, 1)
    $diskList += [PSCustomObject]@{ Drive = $d.DeviceID; TotalGB = $tGB; FreeGB = $fGB; FreeBytes = $d.FreeSpace }
}
$swStage.Stop()
$stageTimings.Add([PSCustomObject]@{ Stage = 'CIM_Hardware_Disk'; TimeAt = $stage1At; DurationMs = $swStage.ElapsedMilliseconds })

# ==============================================================================
# Stage 2: GPU & NVIDIA CUDA
# ==============================================================================
$swStage = [System.Diagnostics.Stopwatch]::StartNew()
$stage2At = (Get-Date).ToString('HH:mm:ss.fff')
if ($isEn) {
    Write-Host "[2/4] ($stage2At) Inspecting GPU, dedicated VRAM usage, and NVIDIA CUDA driver..." -ForegroundColor Cyan
} else {
    Write-Host "[2/4] ($stage2At) 正在检测显卡、显存占用与 CUDA 驱动状态..." -ForegroundColor Cyan
}

$gpuName = 'No dedicated NVIDIA GPU detected'
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
$swStage.Stop()
$stageTimings.Add([PSCustomObject]@{ Stage = 'NVIDIA_SMI_CUDA'; TimeAt = $stage2At; DurationMs = $swStage.ElapsedMilliseconds })

# ==============================================================================
# Stage 3: Developer Toolchain & Conda & PyTorch Probe
# ==============================================================================
$swStage = [System.Diagnostics.Stopwatch]::StartNew()
$stage3At = (Get-Date).ToString('HH:mm:ss.fff')
if ($isEn) {
    Write-Host "[3/4] ($stage3At) Auditing developer toolchain, Conda environments, and PyTorch CUDA..." -ForegroundColor Cyan
} else {
    Write-Host "[3/4] ($stage3At) 正在盘点编程工具链、Conda 环境与 PyTorch CUDA 状态..." -ForegroundColor Cyan
}

$pyVer     = Get-ToolVersion 'python'
$condaVer  = Get-ToolVersion 'conda'
$uvVer     = Get-ToolVersion 'uv'
$gitVer    = Get-ToolVersion 'git'
$nodeVer   = Get-ToolVersion 'node'
$pnpmVer   = Get-ToolVersion 'pnpm'
$rustVer   = Get-ToolVersion 'rustc'
$dotnetVer = Get-ToolVersion 'dotnet'
$dockerVer = Get-ToolVersion 'docker'
$codeVer   = Get-ToolVersion 'code'
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

$torchPyPath    = 'Not Found'
$torchVer       = 'Not Installed'
$torchCudaBuilt = 'False'
$torchCudaVer   = 'None'
$torchCudaAvail = 'False'
$transformersVer = 'Not Installed'
$onnxVer        = 'Not Installed'

if (Get-Command python -ErrorAction SilentlyContinue) {
    $pyMiniProbe = @'
import sys
import importlib.metadata as md
def v(n):
    try: return md.version(n)
    except: return "not_installed"
print("EXEC=" + sys.executable)
print("TORCH=" + v("torch"))
print("TRANSFORMERS=" + v("transformers"))
print("ONNX=" + v("onnxruntime"))
try:
    import torch
    rt = torch.version.cuda
    print("CUDA_RT=" + str(rt))
    print("CUDA_BUILT=" + ("True" if (rt is not None and str(rt) != "None" and str(rt) != "") else "False"))
    print("CUDA_OK=" + str(torch.cuda.is_available()))
except:
    print("CUDA_RT=None")
    print("CUDA_BUILT=False")
    print("CUDA_OK=False")
'@
    try {
        $probeLines = & python -c $pyMiniProbe 2>$null
        foreach ($l in $probeLines) {
            if ($l -match '^EXEC=(.+)$') {
                $p = $Matches[1].Trim()
                if ($env:USERPROFILE) { $p = $p.Replace($env:USERPROFILE, '%USERPROFILE%') }
                $torchPyPath = $p
            }
            if ($l -match '^TORCH=(.+)$') { $torchVer = $Matches[1].Trim() }
            if ($l -match '^TRANSFORMERS=(.+)$') { $transformersVer = $Matches[1].Trim() }
            if ($l -match '^ONNX=(.+)$') { $onnxVer = $Matches[1].Trim() }
            if ($l -match '^CUDA_RT=(.+)$') { $torchCudaVer = $Matches[1].Trim() }
            if ($l -match '^CUDA_BUILT=(.+)$') { $torchCudaBuilt = $Matches[1].Trim() }
            if ($l -match '^CUDA_OK=(.+)$') { $torchCudaAvail = $Matches[1].Trim() }
        }
    } catch {}
}
$swStage.Stop()
$stageTimings.Add([PSCustomObject]@{ Stage = 'Toolchain_PyTorch_Probe'; TimeAt = $stage3At; DurationMs = $swStage.ElapsedMilliseconds })

# ==============================================================================
# Stage 4: Generate Text Report & Anti-Demo HTML Portrait
# ==============================================================================
$swStage = [System.Diagnostics.Stopwatch]::StartNew()
$stage4At = (Get-Date).ToString('HH:mm:ss.fff')
if ($isEn) {
    Write-Host "[4/4] ($stage4At) Generating anti-spoof timestamped portrait webpage (index.html)..." -ForegroundColor Cyan
} else {
    Write-Host "[4/4] ($stage4At) 正在生成带防套壳核验时间戳的可视化侧写页面 (index.html)..." -ForegroundColor Cyan
}

$auditEndTime = Get-Date
$nowStr       = $auditEndTime.ToString('yyyy-MM-dd HH:mm:ss.fff zzz')
$nowUnixMs    = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$auditStopwatch.Stop()
$totalElapsedMs = $auditStopwatch.ElapsedMilliseconds

# Generate tamper-evident live proof hash (Host mask + timestamp + exact free VRAM + disk free bytes + PID)
$machineRaw = "$($env:COMPUTERNAME)|$nowStr|$vramFreeMiB|$($diskList | ForEach-Object { $_.FreeBytes } | Out-String)|$PID"
$sha256 = [System.Security.Cryptography.SHA256]::Create()
$hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($machineRaw))
$hashHex = ([System.BitConverter]::ToString($hashBytes) -replace '-','').Substring(0, 12)
$hostMask = if ($env:COMPUTERNAME.Length -gt 4) { $env:COMPUTERNAME.Substring(0, 4) + "***" } else { "PC***" }
$liveProofId = "PROOF-$hostMask-$hashHex-PID$PID"

Add-Line 'AI PC ENVIRONMENT AUDIT (READ-ONLY)'
Add-Line ('Scan Started   : ' + $auditStartStr)
Add-Line ('Scan Completed : ' + $nowStr)
Add-Line ('Scan Duration  : ' + $totalElapsedMs + ' ms')
Add-Line ('Live Proof ID  : ' + $liveProofId)
Add-Line ('PowerShell     : ' + $PSVersionTable.PSVersion.ToString())
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

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllLines($reportPath, $report, $utf8Bom)

$swStage.Stop()
$stageTimings.Add([PSCustomObject]@{ Stage = 'Report_HTML_Render'; TimeAt = $stage4At; DurationMs = $swStage.ElapsedMilliseconds })

$vramTotalGB = [math]::Round($vramTotalMiB / 1024, 1)
$customEnvs  = @($condaEnvs | Where-Object { $_ -ne 'base' })
$fpId = ("XYJ-{0}-{1}G-{2}C-E{3}" -f ($boardProduct -replace '[^A-Za-z0-9]',''), [math]::Round($vramTotalGB,0), $cpuCores, $customEnvs.Count).ToUpper()

$snapshotObj = [ordered]@{
    selectedLang = $Language
    psVersion = $PSVersionTable.PSVersion.ToString()
    scanStartTimestamp = $auditStartStr
    timestamp = $nowStr
    scanCompletedUnixMs = $nowUnixMs
    scanDurationMs = $totalElapsedMs
    liveProofId = $liveProofId
    stageTimings = $stageTimings
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
        python = if ($pyVer) { $pyVer } else { 'Not found' }
        conda  = if ($condaVer) { $condaVer } else { 'Not found' }
        uv     = if ($uvVer) { $uvVer } else { 'Not found' }
        git    = if ($gitVer) { $gitVer } else { 'Not found' }
        node   = if ($nodeVer) { $nodeVer } else { 'Not found' }
        pnpm   = if ($pnpmVer) { $pnpmVer } else { 'Not found' }
        rust   = if ($rustVer) { $rustVer } else { 'Not found' }
        dotnet = if ($dotnetVer) { $dotnetVer } else { 'Not found' }
        docker = if ($dockerVer) { $dockerVer } else { 'Not found' }
        code   = if ($codeVer) { $codeVer } else { 'Not found' }
        ffmpeg = if ($ffmpegVer) { 'Ready' } else { 'Not found' }
        nvcc   = if ($nvccVer) { 'Installed' } else { 'Not installed' }
    }
    condaEnvs = $customEnvs
    torch = [ordered]@{
        pythonPath    = $torchPyPath
        version       = $torchVer
        cudaBuilt     = $torchCudaBuilt
        cudaRuntime   = $torchCudaVer
        cudaAvailable = $torchCudaAvail
        transformers  = $transformersVer
        onnxruntime   = $onnxVer
    }
    timeInfo = [ordered]@{
        cnDay = $cnDay
        enDay = $dayNameEn
        timePeriod = $timePeriod
        timePeriodEn = $timePeriodEn
        hour = $hourNow
    }
}

$snapshotJsonStr = $snapshotObj | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($jsonPath, $snapshotJsonStr, $utf8Bom)

$prevJsonStr = "null"
if (Test-Path $prevJsonPath) {
    $prevJsonStr = Get-Content -LiteralPath $prevJsonPath -Raw -Encoding UTF8
}

$rawReportEscaped = ($report -join "`n") | ConvertTo-Json

$htmlTemplate = @'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>寻祎居 · 算力底牌侧写 | XunyiJu AI PC Portrait</title>
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
      padding: 20px 28px 64px;
      -webkit-font-smoothing: antialiased;
    }
    .container { max-width: 1360px; margin: 0 auto; }

    /* Anti-Demo Live Verification Strip */
    .antidemo-strip {
      display: flex; align-items: center; justify-content: space-between;
      flex-wrap: wrap; gap: 10px 18px;
      padding: 9px 16px; margin-bottom: 16px;
      border-radius: 10px;
      background: linear-gradient(90deg, rgba(16, 185, 129, 0.1) 0%, rgba(56, 189, 248, 0.08) 100%);
      border: 1px solid rgba(16, 185, 129, 0.28);
      font-size: 12.2px; font-family: var(--font-mono);
      color: #d1fae5;
    }
    .antidemo-left, .antidemo-right {
      display: flex; align-items: center; gap: 14px; flex-wrap: wrap;
    }
    .antidemo-pill {
      display: inline-flex; align-items: center; gap: 6px;
      padding: 2px 9px; border-radius: 999px;
      background: rgba(16, 185, 129, 0.2);
      border: 1px solid rgba(16, 185, 129, 0.45);
      color: #6ee7b7; font-weight: 700; font-size: 11.5px;
    }
    .pulse-dot {
      width: 7px; height: 7px; border-radius: 50%;
      background: #10b981;
      box-shadow: 0 0 8px #10b981;
    }
    .antidemo-kv { color: var(--text-secondary); }
    .antidemo-kv strong { color: var(--text-white); font-weight: 600; }

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
    .topbar-right { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
    .legend-bar {
      display: flex; align-items: center; gap: 16px;
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
    .lang-switch {
      display: inline-flex; align-items: center;
      background: var(--bg-card-subtle);
      border: 1px solid var(--border-focus);
      border-radius: 999px; padding: 2px;
    }
    .lang-btn {
      appearance: none; border: none; background: transparent;
      color: var(--text-secondary); font-size: 12px; font-weight: 600;
      padding: 4px 12px; border-radius: 999px; cursor: pointer;
      transition: all 0.15s ease;
    }
    .lang-btn.active {
      background: rgba(16, 185, 129, 0.2);
      color: #6ee7b7;
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
      display: flex; align-items: flex-start; justify-content: space-between;
      margin-bottom: 22px; flex-wrap: wrap; gap: 10px;
    }
    .card-eyebrow {
      font-size: 11px; text-transform: uppercase;
      letter-spacing: 0.1em; color: var(--text-muted);
      font-family: var(--font-mono);
    }
    .card-title { font-size: 22px; font-weight: 700; color: var(--text-white); }
    .card-meta-box {
      display: flex; flex-direction: column; align-items: flex-end; gap: 3px;
      font-size: 11.8px; color: var(--text-secondary); font-family: var(--font-mono);
      background: rgba(255, 255, 255, 0.03);
      padding: 6px 11px; border-radius: 8px;
      border: 1px solid var(--border-subtle);
    }
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
    .fp-label { font-size: 11.5px; color: var(--text-muted); display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
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
    .fp-timings {
      font-size: 11.2px; font-family: var(--font-mono); color: #86efac;
      background: rgba(16, 185, 129, 0.07); border: 1px solid rgba(16, 185, 129, 0.2);
      padding: 4px 8px; border-radius: 6px; margin-top: 2px;
    }
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
    .priority-list { list-style: none; display: flex; flex-direction: column; gap: 12px; font-size: 13px; }
    .priority-item { display: flex; flex-direction: column; gap: 5px; padding-bottom: 10px; border-bottom: 1px dashed rgba(255, 255, 255, 0.07); }
    .priority-item:last-child { padding-bottom: 0; border-bottom: none; }
    .priority-item-head { font-weight: 600; color: var(--text-white); }
    .priority-item-desc { color: var(--text-secondary); font-size: 12.2px; line-height: 1.5; }

    /* Fixed Command Box: No ugly horizontal scrollbar! Clean wrap + 1-click Copy Button + Domestic Mirror Badge */
    .priority-cmd-wrap {
      margin-top: 4px;
      background: rgba(0, 0, 0, 0.42);
      border: 1px solid rgba(56, 189, 248, 0.22);
      border-radius: 8px;
      padding: 8px 10px;
      display: flex; flex-direction: column; gap: 6px;
    }
    .priority-cmd-top {
      display: flex; align-items: center; justify-content: space-between; gap: 8px;
    }
    .mirror-badge {
      font-size: 10.5px; font-weight: 600;
      color: #6ee7b7; background: rgba(16, 185, 129, 0.15);
      padding: 1px 7px; border-radius: 4px;
      border: 1px solid rgba(16, 185, 129, 0.3);
    }
    .cmd-copy-btn {
      appearance: none; border: 1px solid rgba(255, 255, 255, 0.15);
      background: rgba(255, 255, 255, 0.06); color: var(--text-primary);
      font-size: 11px; padding: 2px 8px; border-radius: 5px;
      cursor: pointer; transition: all 0.15s ease;
    }
    .cmd-copy-btn:hover {
      background: rgba(16, 185, 129, 0.25); border-color: var(--accent-green); color: #fff;
    }
    .priority-cmd {
      font-family: var(--font-mono); font-size: 11.3px;
      color: #93c5fd; line-height: 1.5;
      white-space: pre-wrap; word-break: break-all;
      user-select: all;
    }

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
    .appendix-filter { background: var(--bg-base); border: 1px solid var(--border-subtle); color: var(--text-primary); padding: 5px 11px; border-radius: 6px; font-size: 12px; width: 240px; outline: none; }
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
    <!-- Top Anti-Demo Live Verification Strip -->
    <div class="antidemo-strip" id="antiDemoStrip">
      <div class="antidemo-left">
        <span class="antidemo-pill"><span class="pulse-dot"></span><span id="uiAntiDemoBadge">真机实时检索 · 防套壳核验</span></span>
        <span class="antidemo-kv" id="uiScanTimeKv"></span>
        <span class="antidemo-kv" id="uiScanDurKv"></span>
      </div>
      <div class="antidemo-right">
        <span class="antidemo-kv" id="uiLiveViewKv"></span>
        <span class="antidemo-kv" id="uiProofKv"></span>
      </div>
    </div>

    <header class="topbar">
      <div class="brand-group">
        <span class="brand-badge"><span class="dot"></span><span id="uiBrandBadge">寻祎居 · 算力底牌侧写</span></span>
        <h1 class="brand-title" id="uiBrandTitle">你是谁 · AI 眼里的这台电脑</h1>
        <span class="brand-sub" id="uiBrandSub">零联网本地只读扫描</span>
      </div>
      <div class="topbar-right">
        <div class="legend-bar" id="uiLegendBar"></div>
        <div class="lang-switch" aria-label="Language Switcher">
          <button type="button" class="lang-btn" id="btnLangZh">简体中文</button>
          <button type="button" class="lang-btn" id="btnLangEn">English</button>
        </div>
      </div>
    </header>

    <main class="main-grid">
      <section class="left-col">
        <article class="card">
          <div class="card-header">
            <div>
              <div class="card-eyebrow">LOCAL AI CAPABILITY PORTRAIT</div>
              <h2 class="card-title" id="uiLeftTitle">「AI 模型眼里的你」</h2>
            </div>
            <div class="card-meta-box">
              <div id="metaTimestamp"></div>
              <div id="metaViewTimestamp" style="color:#6ee7b7;"></div>
            </div>
          </div>

          <div class="narrative-body" id="narrativeContainer"></div>

          <div class="fingerprint-box">
            <div class="fp-left">
              <div class="fp-label">
                <span id="uiFpLabel">本机特征指纹 ID</span>
                <span class="fp-tag" id="uiFpTag">本地生成</span>
                <span class="fp-tag" id="uiProofTag" style="background:rgba(16,185,129,0.12);color:#6ee7b7;border-color:rgba(16,185,129,0.3);"></span>
              </div>
              <div class="fp-id" id="fpHashText"></div>
              <div class="fp-sub" id="fpSubText"></div>
              <div class="fp-timings" id="fpStageTimings"></div>
            </div>
            <div class="fp-diff">
              <div class="diff-title">
                <span id="uiDiffTitle">跟上回扫描比有什么变化</span>
                <span class="diff-badge" id="diffBadge"></span>
              </div>
              <ul class="diff-list" id="diffList"></ul>
            </div>
          </div>

          <div class="action-bar">
            <button class="btn btn-primary" id="btnCopyPortrait" type="button"></button>
            <button class="btn" id="btnCopyJson" type="button"></button>
            <button class="btn" id="btnToggleClues" type="button"></button>
            <button class="btn" id="btnViewRaw" type="button"></button>
            <button class="btn" id="btnCopyCmd" type="button"></button>
          </div>
        </article>

        <section class="appendix-card">
          <div class="appendix-header">
            <div class="appendix-title" id="appendixTitle"></div>
            <input type="search" id="appendixSearch" class="appendix-filter" />
          </div>
          <div class="appendix-grid" id="appendixGrid"></div>
        </section>
      </section>

      <aside class="right-col">
        <article class="card diag-card">
          <div class="card-header" style="margin-bottom: 14px;">
            <div>
              <div class="card-eyebrow">BOTTLENECK &amp; EXPOSURE AUDIT</div>
              <h2 class="card-title" id="uiRightTitle">「破绽与卡点诊断」</h2>
            </div>
          </div>

          <div class="diag-hero">
            <div class="diag-count-wrap">
              <span class="diag-big-num" id="diagBigNum">0</span>
              <span class="diag-count-text" id="uiDiagCountText">处地方可能卡住你</span>
            </div>
            <span class="grade-badge" id="gradeBadge"></span>
          </div>

          <div class="segment-wrap">
            <div class="segment-bar" id="segmentBar"></div>
            <div class="segment-labels" id="segmentLabels"></div>
          </div>

          <div class="priority-box">
            <div class="priority-header">
              <span class="priority-title" id="uiPriorityTitle">🔥 先改这几项</span>
              <span class="priority-tag" id="priorityTag"></span>
            </div>
            <ul class="priority-list" id="priorityList"></ul>
          </div>

          <div class="checklist-section-title" id="uiChecklistHeader">逐项大白话清单</div>
          <ul class="checklist" id="checklistContainer"></ul>
        </article>
      </aside>
    </main>
  </div>

  <div class="clue-popover" id="cluePopover" role="tooltip">
    <div class="pop-type" id="popType"></div>
    <div class="pop-field" id="popField"></div>
    <div class="pop-reason" id="popReason"></div>
  </div>

  <div class="modal-backdrop" id="rawModal">
    <div class="modal-box">
      <div class="modal-head">
        <span id="uiModalTitle">AI_PC_Report.txt</span>
        <button class="btn" id="btnCloseModal" type="button" style="padding: 4px 10px;">✕</button>
      </div>
      <pre class="modal-pre" id="rawReportContent"></pre>
    </div>
  </div>

  <div class="toast" id="toast"></div>

  <script>
    const SNAPSHOT = __SNAPSHOT_JSON__;
    const PREV_SNAPSHOT = __PREV_JSON__;
    const RAW_REPORT_TEXT = __RAW_REPORT_JSON__;

    let currentLang = (SNAPSHOT.selectedLang === 'en') ? 'en' : 'zh';
    let expanded = false;
    let pinnedClue = null;

    function formatNowTime() {
      const d = new Date();
      const pad = (n, w = 2) => String(n).padStart(w, '0');
      return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
    }

    function updateAntiDemoClock() {
      const en = (currentLang === 'en');
      const nowMs = Date.now();
      const scanMs = SNAPSHOT.scanCompletedUnixMs || nowMs;
      const diffSec = Math.max(0, Math.floor((nowMs - scanMs) / 1000));
      let elapsedText = '';
      if (diffSec < 60) {
        elapsedText = en ? `${diffSec}s ago` : `${diffSec} 秒前刚出结果`;
      } else if (diffSec < 3600) {
        const m = Math.floor(diffSec / 60);
        const s = diffSec % 60;
        elapsedText = en ? `${m}m ${s}s ago` : `距出结果 ${m} 分 ${s} 秒`;
      } else {
        const h = Math.floor(diffSec / 3600);
        const m = Math.floor((diffSec % 3600) / 60);
        elapsedText = en ? `${h}h ${m}m ago` : `距出结果 ${h} 小时 ${m} 分`;
      }

      const nowStr = formatNowTime();
      document.getElementById('uiAntiDemoBadge').textContent = en ? 'Live Local Probe · Anti-Demo Verified' : '真机实时检索 · 防 Demo 套壳核验';
      document.getElementById('uiScanTimeKv').innerHTML = en
        ? `Result Retrieved: <strong>${SNAPSHOT.timestamp}</strong>`
        : `检索出结果时间：<strong>${SNAPSHOT.timestamp}</strong>`;
      document.getElementById('uiScanDurKv').innerHTML = en
        ? `Probe Elapsed: <strong>${SNAPSHOT.scanDurationMs} ms</strong>`
        : `真机检索耗时：<strong>${SNAPSHOT.scanDurationMs} ms (${(SNAPSHOT.scanDurationMs / 1000).toFixed(2)}s)</strong>`;
      document.getElementById('uiLiveViewKv').innerHTML = en
        ? `Viewing At: <strong>${nowStr} (${elapsedText})</strong>`
        : `当前查看时间：<strong>${nowStr}（${elapsedText}）</strong>`;
      document.getElementById('uiProofKv').innerHTML = `Proof: <strong>${SNAPSHOT.liveProofId}</strong>`;

      document.getElementById('metaTimestamp').textContent = (en ? 'Retrieved At: ' : '检索出结果时间：') + SNAPSHOT.timestamp;
      document.getElementById('metaViewTimestamp').textContent = (en ? 'Viewing Now: ' : '当前打开查看时间：') + nowStr + ' (' + elapsedText + ')';
    }

    setInterval(updateAntiDemoClock, 1000);

    function clue(type, text, field, reason) {
      const cls = type === 'red' ? 'clue clue-red' : type === 'infer' ? 'clue clue-infer' : 'clue clue-fact';
      const escField = String(field).replace(/"/g, '&quot;');
      const escReason = String(reason).replace(/"/g, '&quot;');
      return `<span class="${cls}" data-type="${type}" data-field="${escField}" data-reason="${escReason}">${text}</span>`;
    }

    function buildPortrait(s, lang) {
      const vramGB = (s.vramTotalMiB / 1024).toFixed(0);
      const vramFreeGB = (s.vramFreeMiB / 1024).toFixed(2);
      const vramUsedGB = (s.vramUsedMiB / 1024).toFixed(2);
      const disks = s.disks || [];
      let biggestDisk = disks[0] || { Drive: 'C:', FreeGB: 0, TotalGB: 0 };
      disks.forEach(d => { if (d.FreeGB > biggestDisk.FreeGB) biggestDisk = d; });
      const installedTools = Object.entries(s.tools).filter(([_, v]) => v && !String(v).includes('Not')).map(([k]) => k);
      const envList = s.condaEnvs || [];

      if (lang === 'en') {
        const p1 = `You are running ${clue('fact', s.os, 'OS: ' + s.os + ' (Build ' + s.osBuild + ')', 'Read directly from Windows CIM Win32_OperatingSystem.')} on an ${clue('fact', s.brand + ' ' + s.model, 'Model: ' + s.brand + ' ' + s.model + ' / Board ' + s.board, 'Hardware identity reported by the motherboard BIOS.')}. Out of ${disks.length} local drives, ${clue('infer', 'drive ' + biggestDisk.Drive + ' has ' + biggestDisk.FreeGB + ' GB sitting wide open', biggestDisk.Drive + ' Total ' + biggestDisk.TotalGB + ' GB / Free ' + biggestDisk.FreeGB + ' GB', 'The partition with the most free space is the natural home for multi-gigabyte model checkpoints.')}, which is where your heavy model weights belong.`;

        const p2Parts = [];
        if (s.vramTotalMiB > 0 && s.vramTotalMiB <= 8500 && s.ramGB <= 16.5) {
          p2Parts.push(`${clue('red', vramGB + ' GB VRAM paired with ' + Math.round(s.ramGB) + ' GB system RAM is a tight squeeze', 'VRAM: ' + s.vramTotalMiB + ' MiB / RAM: ' + s.ramGB + ' GB (' + s.ramModules + ')', 'When a model overflows 8 GB VRAM, it offloads layers into system RAM. With 16 GB RAM, Windows leaves only ~7 GB free before hitting slow disk swap.')} when offloading large diffusion or video models`);
        } else if (s.vramTotalMiB === 0) {
          p2Parts.push(`${clue('red', 'no active NVIDIA discrete GPU was detected', 'GPU: ' + s.gpu, 'Without an NVIDIA GPU and driver, local generation falls back to CPU.')}`);
        }
        const pyPath = s.torch.pythonPath || 'default python';
        const torchInstalled = (s.torch.version && s.torch.version !== 'not_installed' && s.torch.version !== 'Not Installed');
        const cudaBuilt = (s.torch.cudaBuilt === 'True' || (s.torch.cudaRuntime && s.torch.cudaRuntime !== 'None'));
        const cudaAvail = (s.torch.cudaAvailable === 'True');

        if (!torchInstalled) {
          p2Parts.push(`${clue('infer', 'PyTorch is not installed in the probed default Python (' + pyPath + ')', 'Probed Python: ' + pyPath + ' / torch: not_installed', 'Note: ComfyUI Portable/Desktop and Conda environments use their own isolated Python runtimes, so you do not need PyTorch in the system default Python unless you run scripts there directly.')}`);
        } else if (cudaBuilt && !cudaAvail) {
          p2Parts.push(`${clue('red', 'PyTorch in ' + pyPath + ' IS built with CUDA (' + s.torch.cudaRuntime + '), but CUDA is currently unavailable at runtime', 'Probed Python: ' + pyPath + ' | torch: ' + s.torch.version + ' | CUDA Build: ' + s.torch.cudaRuntime + ' | cuda.is_available: False', 'Do NOT reinstall PyTorch! The package already supports CUDA, but the GPU driver is not responding, outdated, or disabled in this session.')}`);
        } else if (!cudaBuilt) {
          p2Parts.push(`${clue('red', 'the probed default Python (' + pyPath + ') has a CPU-only build of PyTorch', 'Probed Python: ' + pyPath + ' | torch: ' + s.torch.version + ' | CUDA Build: None', 'Note: This only applies to the system default Python (' + pyPath + '). ComfyUI or Conda environments use their own separate Python runtimes.')}`);
        }
        const p2 = p2Parts.length > 0
          ? `Things to note when running local AI: ${p2Parts.join('; and ')}.`
          : `Your VRAM, system RAM, and the PyTorch CUDA runtime in ${clue('fact', pyPath, 'Probed Python: ' + pyPath + ' | torch: ' + s.torch.version, 'Actual Python executable probed in this session (ComfyUI/Conda may use separate environments).')} are properly aligned.`;

        let tierText = 'a solid everyday PC';
        if (s.vramTotalMiB >= 15500) tierText = 'a heavy-duty local AI rig';
        else if (s.vramTotalMiB >= 7500) tierText = 'a capable mid-high machine capped mainly by memory capacity';
        else if (s.vramTotalMiB >= 4000) tierText = 'an entry-level discrete GPU machine for quantized models';

        const p3 = `In plain terms, this is ${clue('infer', tierText, 'CPU: ' + s.cpu + ' + GPU: ' + s.gpu, 'Hardware tier judged by CPU core count and dedicated VRAM ceiling.')}. The ${clue('fact', s.cpuCores + '-core / ' + s.cpuThreads + '-thread ' + s.cpu, 'Processor: ' + s.cpu, 'Handles tokenization, data loading, and CPU-offloaded layers.')} paired with ${clue('fact', s.gpu + ' (' + vramGB + ' GB VRAM)', 'GPU: ' + s.gpu + ' / VRAM: ' + s.vramTotalMiB + ' MiB', 'Dedicated graphics memory.')} handles 7B/8B Q4 LLMs, SDXL image generation, and ${clue('infer', 'low-VRAM video workflows like Wan 2.2 5B or FramePack', 'Free VRAM: ~' + vramFreeGB + ' GB', 'With GGUF Q4 quantization and Tiled VAE decoding, 5B video models fit inside an 8 GB budget.')} well. Full unquantized 14B video models will stall without more RAM.`;

        const p4 = s.vramUsedMiB > 1200
          ? `Looking at its idle posture, ${clue('red', 'background apps have already eaten ' + vramUsedGB + ' GB of VRAM before you even start', 'VRAM Used: ' + s.vramUsedMiB + ' MiB / Free: ' + s.vramFreeMiB + ' MiB', 'Desktop compositing, browser hardware acceleration, or virtual displays consume nearly 2 GB of dedicated VRAM.')}, leaving you ${clue('fact', vramFreeGB + ' GB of net free VRAM', 'memory.free: ' + s.vramFreeMiB + ' MiB', 'Actual headroom left for model weights and activations.')}. Also, your GPU power limit is currently capped at ${clue('fact', s.gpuPowerCap, 'Power Draw/Cap: ' + s.gpuPowerDraw + ' / ' + s.gpuPowerCap, 'Laptop balanced mode lowers the GPU power ceiling.')}. Close background GPU hogs and switch to Performance mode before heavy runs.`
          : `Your idle VRAM footprint is clean: background processes use only ${clue('fact', vramUsedGB + ' GB, leaving ' + vramFreeGB + ' GB free', 'Used: ' + s.vramUsedMiB + ' MiB / Free: ' + s.vramFreeMiB + ' MiB', 'Most of your dedicated VRAM is available for AI workloads.')}, with a current GPU power cap of ${clue('fact', s.gpuPowerCap, 'Power Cap: ' + s.gpuPowerCap, 'Reported by nvidia-smi.')}.`;

        const envText = envList.length > 0
          ? ` and set up ${clue('infer', envList.length + ' custom Conda environments (' + envList.slice(0, 8).join(', ') + (envList.length > 8 ? ', etc.' : '') + ')', 'Conda Envs: ' + envList.join(', '), 'Isolated environments reflect the specific AI and dev projects you work on.')}`
          : '';
        const p5 = `Your installed tools show you write code and tinker with local projects: ${clue('fact', installedTools.join(', '), 'CLI tools available in PATH', 'Detected directly in the current terminal PATH.')} are all wired up${envText}. As for your real name, age, or appearance, a local hardware script cannot see them and we do not guess.`;

        const p6 = `This live probe started at ${clue('fact', s.scanStartTimestamp + ' and finished in ' + s.scanDurationMs + ' ms', 'Start: ' + s.scanStartTimestamp + ' -> End: ' + s.timestamp + ' (' + s.liveProofId + ')', 'Real-time local execution timestamps proving this report is not a static demo shell.')} on PowerShell ${s.psVersion}, with the GPU sitting at ${clue('fact', s.gpuTemp + ' drawing ' + s.gpuPowerDraw, 'Temp: ' + s.gpuTemp + ' / Power: ' + s.gpuPowerDraw + ' / State: ' + s.gpuPerfState, 'Live sensor reading from nvidia-smi.')}.`;

        const p7 = `As a local hardware fingerprint, three traits stand out most: ${clue('fact', s.cpu + ' paired with ' + s.gpu, 'Core Compute', 'Primary CPU + GPU combination.')}, ${clue('fact', biggestDisk.FreeGB + ' GB of open storage on drive ' + biggestDisk.Drive, 'Storage Headroom', 'Best partition for model weights.')}, and ${s.ramGB <= 16.5 ? clue('red', 'the ' + s.ramModules + ' RAM setup that will benefit hugely from a 32 GB or 64 GB upgrade', 'RAM: ' + s.ramModules, 'Upgrading SODIMM RAM is the highest-ROI hardware change for this laptop.') : clue('fact', 'your ' + s.ramModules + ' system memory configuration', 'RAM: ' + s.ramModules, 'System memory configuration.')}.`;

        return [p1, p2, p3, p4, p5, p6, p7];
      }

      // Simplified Chinese (zh)
      const p1 = `你现在用的是 ${clue('fact', s.os, 'OS: ' + s.os + ' (Build ' + s.osBuild + ')', '从系统底层读取到的 Windows 版本号。')}，面前这台机器是 ${clue('fact', s.brand + ' ' + s.model, 'Model: ' + s.brand + ' ' + s.model + ' / 主板 ' + s.board, '直接读取主板与整机型号得出的硬件身份。')}。系统里挂着 ${disks.length} 个本地分区，其中 ${clue('infer', biggestDisk.Drive + ' 盘空着 ' + biggestDisk.FreeGB + 'GB 没动', biggestDisk.Drive + ' 总计 ' + biggestDisk.TotalGB + 'GB / 空闲 ' + biggestDisk.FreeGB + 'GB', '哪个盘剩余空间最大，大模型权重和素材库就最该往哪儿放。')}，拿来囤几十个 G 的本地模型权重正合适。`;

      const p2Parts = [];
      if (s.vramTotalMiB > 0 && s.vramTotalMiB <= 8500 && s.ramGB <= 16.5) {
        p2Parts.push(`一个是 ${clue('red', vramGB + 'GB 显存配 ' + Math.round(s.ramGB) + 'GB 内存的组合有点卡脖子', 'VRAM: ' + s.vramTotalMiB + ' MiB / RAM: ' + s.ramGB + ' GB (' + s.ramModules + ')', '显存装不下的模型得借用系统内存，16GB 内存扣掉系统自用只剩七八个 G，跑大视频模型很容易吃满卡死。')}，跑小模型挺顺，一碰要借内存的大块头就会狂刷硬盘虚拟内存`);
      } else if (s.vramTotalMiB === 0) {
        p2Parts.push(`最明显的是 ${clue('red', '机子里没检出能干活的 NVIDIA 独显', 'GPU: ' + s.gpu, '没有独显或者没装好 NVIDIA 驱动，本地跑生图和视频只能靠 CPU 硬扛。')}`);
      }
      const pyPathZh = s.torch.pythonPath || '当前终端默认 Python';
      const torchInstalledZh = (s.torch.version && s.torch.version !== 'not_installed' && s.torch.version !== 'Not Installed');
      const cudaBuiltZh = (s.torch.cudaBuilt === 'True' || (s.torch.cudaRuntime && s.torch.cudaRuntime !== 'None'));
      const cudaAvailZh = (s.torch.cudaAvailable === 'True');

      if (!torchInstalledZh) {
        p2Parts.push(`另外在本次检测的默认 Python（${clue('fact', pyPathZh, '实际检测 Python 路径: ' + pyPathZh, '仅代表当前终端 PATH 命中的默认 Python；ComfyUI 便携版 (python_embeded)、桌面版或 Conda 环境各自有独立的 Python。')}）里暂未安装 PyTorch（如果你平时用 ComfyUI 或 Conda 独立环境，这完全正常，无需在默认 Python 里安装）`);
      } else if (cudaBuiltZh && !cudaAvailZh) {
        p2Parts.push(`另一个是本次检测的 Python（${clue('fact', pyPathZh, '实际检测 Python 路径: ' + pyPathZh, '本次探针实际检测的 Python 解释器路径。')}）虽然 ${clue('red', '已经装了支持 CUDA ' + s.torch.cudaRuntime + ' 的 PyTorch，但当前却无法调起显卡', 'torch: ' + s.torch.version + ' | 支持 CUDA: ' + s.torch.cudaRuntime + ' | 当前可用: False', '注意：安装包本身已经是支持 CUDA 的版本，不是 CPU 版！千万别盲目重装 PyTorch，请优先检查 NVIDIA 显卡驱动版本、是否刚更完驱动没重启，或设备管理器中独显是否异常。')}`);
      } else if (!cudaBuiltZh) {
        p2Parts.push(`另一个是本次检测的默认 Python（${clue('fact', pyPathZh, '实际检测 Python 路径: ' + pyPathZh, '注意：这只是系统默认 Python，不一定是 ComfyUI 或 Conda 正在用的环境。')}）里 ${clue('red', '装的是不支持 CUDA 的纯 CPU 构建版 PyTorch', 'torch: ' + s.torch.version + ' | 支持 CUDA: False (torch.version.cuda=None) | 当前可用: False', '只有当你确实直接用这个默认 Python 跑 AI 脚本时才需要换装；若你用的是 ComfyUI 内置环境或 Conda 虚拟环境，请勿在默认 Python 中盲目重装。')}`);
      }
      const p2 = p2Parts.length > 0
        ? `真要跑起本地 AI，这台电脑目前需要注意的地方有：${p2Parts.join('；')}。`
        : `从底层配置看，你的显存、内存以及本次检测的默认 Python（${clue('fact', pyPathZh, '实际检测路径: ' + pyPathZh + ' | torch: ' + s.torch.version, '支持 CUDA ' + s.torch.cudaRuntime + ' 且当前 torch.cuda.is_available()=True。注：ComfyUI/Conda 可能使用各自独立的 Python 环境。')}）都已经打通显卡 CUDA 加速。`;

      let tierText = '中规中矩的家用办公机';
      if (s.vramTotalMiB >= 15500) tierText = '能直接硬啃大模型的重型算力机';
      else if (s.vramTotalMiB >= 7500) tierText = '算力底子不错、但被显存和内存容量框住上限的甜点机';
      else if (s.vramTotalMiB >= 4000) tierText = '适合跑轻量量化模型的入门独显机';

      const p3 = `按跑 AI 的标准来给硬件定个档，它属于 ${clue('infer', tierText, 'CPU: ' + s.cpu + ' + GPU: ' + s.gpu, '综合处理器核心数与独立显存大小给出的档位定性。')}。${clue('fact', s.cpuCores + ' 核 ' + s.cpuThreads + ' 线程的 ' + s.cpu, 'Processor: ' + s.cpu, '多核处理器负责数据加载、分词和前后处理。')} 搭上 ${clue('fact', s.gpu + '（' + vramGB + 'GB 独立显存）', 'GPU: ' + s.gpu + ' / VRAM: ' + s.vramTotalMiB + ' MiB', '决定你能装下多大模型的硬指标。')}，日常跑 7B/8B 聊天模型、SDXL 画图，或者 ${clue('infer', 'Wan 2.2 5B、FramePack 这类专门做过低显存优化的视频模型', '可用净显存约 ' + vramFreeGB + 'GB', '8GB 显存配合 GGUF Q4 量化和分块 VAE 解码，跑 5B 级视频模型刚刚好。')} 都兜得住；但别强行上未量化的原版大模型。`;

      const p4 = s.vramUsedMiB > 1200
        ? `再看它现在的待机姿态，${clue('red', '还没开跑就已经被后台偷走了 ' + vramUsedGB + 'GB 显存', 'VRAM Used: ' + s.vramUsedMiB + ' MiB / Free: ' + s.vramFreeMiB + ' MiB', '桌面窗口、浏览器硬件加速或模拟器占掉了近 2GB 显存，跑视频到最后一步解码时极易因为差这点显存而崩掉。')}，满打满算只留给你 ${clue('fact', vramFreeGB + 'GB 的净显存', 'memory.free: ' + s.vramFreeMiB + ' MiB', '当前真正能给 AI 模型分配的剩余独立显存。')}。而且显卡功耗上限目前停在 ${clue('fact', s.gpuPowerCap, 'Power Draw/Cap: ' + s.gpuPowerDraw + ' / ' + s.gpuPowerCap, '笔记本在平衡或安静模式下会限制显卡最高功耗。')}，跑重活前记得插紧电源、切到性能模式，并把占显存的后台软件关掉。`
        : `目前机器的待机姿态挺干净，后台只占了 ${clue('fact', vramUsedGB + 'GB 显存，留出 ' + vramFreeGB + 'GB 净空间', 'Used: ' + s.vramUsedMiB + ' MiB / Free: ' + s.vramFreeMiB + ' MiB', '后台显存占用控制得很好，大部分显存都能留给模型。')}，显卡当前功耗上限为 ${clue('fact', s.gpuPowerCap, 'Power Cap: ' + s.gpuPowerCap, '当前驱动汇报的功耗上限。')}。`;

      const envText = envList.length > 0
        ? `，还在 Conda 里建了 ${clue('infer', envList.length + ' 个独立环境（' + envList.slice(0, 8).join('、') + (envList.length > 8 ? ' 等' : '') + '）', 'Conda Envs: ' + envList.join(', '), '每个虚拟环境对应一个折腾过的项目，从名字就能看出平时在跑哪些业务。')}`
        : '';
      const p5 = `翻一下装好的工具链就知道你平时没少折腾代码：机子里能直接调起 ${clue('fact', installedTools.join('、'), 'Detected CLI Tools in PATH', '这些开发工具全部在终端 PATH 中可直接调用。')}${envText}。至于你的真实姓名、年龄和长相，本地硬件脚本读不出来，这里也不瞎猜。`;

      const p6 = `本次真机检索在 ${clue('fact', s.timeInfo.cnDay + s.timeInfo.timePeriod + '（' + s.timestamp + '，全程实测耗时 ' + s.scanDurationMs + ' 毫秒）', '启动: ' + s.scanStartTimestamp + ' -> 完成: ' + s.timestamp + ' / 校验码: ' + s.liveProofId, '精确到毫秒的本机探针检索时间戳与防套壳校验码，证明非静态 Demo 页面。')} 完成，显卡核心温度 ${clue('fact', s.gpuTemp + '，当前功耗 ' + s.gpuPowerDraw, 'Temp: ' + s.gpuTemp + ' / Power: ' + s.gpuPowerDraw + ' / State: ' + s.gpuPerfState, 'nvidia-smi 实时读取到的显卡传感器状态。')}，风扇还没怎么转，正处于随时能拉起来干活的轻载状态。`;

      const p7 = `综合算下来，这台电脑的本地特征辨识度很高。最显眼的地方有三处：${clue('fact', s.cpu + ' 搭 ' + s.gpu + ' 的硬件底子', 'CPU + GPU Combo', '核心算力组合。')}、${clue('fact', biggestDisk.Drive + ' 盘那 ' + biggestDisk.FreeGB + 'GB 的空闲空间', 'Max Free Disk: ' + biggestDisk.Drive, '模型存储主力分区。')}，以及 ${s.ramGB <= 16.5 ? clue('red', '目前最值得花点小钱升到 32GB 以上的 ' + s.ramModules + ' 内存', 'RAM: ' + s.ramModules, '把 16GB 内存升到 32GB 或 64GB，是这台笔记本提升大模型兼容性性价比最高的一步。') : clue('fact', s.ramModules + ' 的充裕内存配置', 'RAM: ' + s.ramModules, '内存容量充足，支持模型分块卸载。')}。`;

      return [p1, p2, p3, p4, p5, p6, p7];
    }

    function buildDiagnosis(s, lang) {
      const issues = [];
      const goods = [];
      const topFixes = [];
      const en = (lang === 'en');

      const pyPath = s.torch.pythonPath || 'default python';
      const torchInstalled = (s.torch.version && s.torch.version !== 'not_installed' && s.torch.version !== 'Not Installed');
      const cudaBuilt = (s.torch.cudaBuilt === 'True' || (s.torch.cudaRuntime && s.torch.cudaRuntime !== 'None'));
      const cudaAvail = (s.torch.cudaAvailable === 'True');

      if (!torchInstalled) {
        issues.push({
          level: 'amber',
          title: en ? ('No PyTorch in probed default Python (' + pyPath + ')') : ('本次检测的默认 Python 未安装 PyTorch'),
          note: en
            ? ('Probed path: ' + pyPath + '. Note: ComfyUI Portable (python_embeded), ComfyUI Desktop, and Conda environments use their own isolated Python runtimes. You do NOT need to install PyTorch here unless you run scripts directly with this default Python.')
            : ('实际检测路径：' + pyPath + '。注意：这只是系统默认 Python，不一定是 ComfyUI 或 Conda 正在用的环境。如果你平时用 ComfyUI 便携版/桌面版或 Conda 虚拟环境，它们有自己独立的 Python，无需在系统默认 Python 中安装。')
        });
      } else if (cudaBuilt && !cudaAvail) {
        issues.push({
          level: 'red',
          title: en
            ? ('PyTorch supports CUDA (' + s.torch.cudaRuntime + '), but CUDA is currently unavailable')
            : ('PyTorch 本身支持 CUDA (' + s.torch.cudaRuntime + ')，但当前无法调起显卡'),
          note: en
            ? ('Probed path: ' + pyPath + ' | torch ' + s.torch.version + '. Do NOT reinstall PyTorch—your package is already a CUDA build! Check if your NVIDIA driver is too old for CUDA ' + s.torch.cudaRuntime + ', needs a reboot after driver update, or the GPU is disabled.')
            : ('实际检测路径：' + pyPath + '（torch ' + s.torch.version + '）。注意：你装的已经是支持 CUDA ' + s.torch.cudaRuntime + ' 的版本，并非 CPU 版，切勿盲目重装 PyTorch！当前 cuda.is_available()=False 通常是因为显卡驱动版本低于 CUDA ' + s.torch.cudaRuntime + ' 要求、刚更新驱动尚未重启，或独显在设备管理器中异常。')
        });
        topFixes.push({
          head: en ? 'Check NVIDIA Driver / Reboot (Do NOT reinstall PyTorch)' : '排查显卡驱动或重启电脑（无需重装 PyTorch！）',
          desc: en
            ? ('PyTorch in ' + pyPath + ' already has CUDA ' + s.torch.cudaRuntime + ' compiled in, so reinstalling PyTorch will not help. Run nvidia-smi to verify your driver and reboot if you recently updated drivers.')
            : ('实测 ' + pyPath + ' 下的 PyTorch (' + s.torch.version + ') 已经内置 CUDA ' + s.torch.cudaRuntime + ' 支持，重装 PyTorch 毫无意义。请检查 NVIDIA 驱动版本（当前最高支持 CUDA ' + s.cudaMax + '）或重启系统让驱动生效。'),
          cmd: ''
        });
      } else if (!cudaBuilt) {
        issues.push({
          level: 'amber',
          title: en
            ? ('Probed default Python has a CPU-only PyTorch build (' + s.torch.version + ')')
            : ('本次检测的默认 Python 装的是纯 CPU 构建版 PyTorch (' + s.torch.version + ')'),
          note: en
            ? ('Probed path: ' + pyPath + ' (torch.version.cuda=None). Note: ComfyUI and Conda environments use their own separate Python. Only replace this if you directly run AI scripts using this exact Python executable.')
            : ('实际检测路径：' + pyPath + '（支持 CUDA: 否 / 当前可用: 否）。特别提醒：报告测的只是系统默认 Python，不一定是 ComfyUI 或 Conda 正在用的环境！如果你平时只用 ComfyUI 便携版/桌面版或特定 Conda 环境，请直接忽略此项，不要按下面命令重装。')
        });
        topFixes.push({
          head: en
            ? 'Optional: Switch default Python PyTorch to CUDA build (Skip if using ComfyUI/Conda)'
            : '【仅当你直接用该默认 Python 跑 AI 时】为其换装支持 CUDA 的 PyTorch',
          desc: en
            ? ('Target Python: ' + pyPath + '. If you use ComfyUI Portable/Desktop or Conda, skip this! Only run if you use this exact default Python:')
            : ('目标路径：' + pyPath + '。如果你平时使用的是 ComfyUI 独立环境或 Conda 虚拟环境，请只做扫描参考，不要执行重装！仅当你确实要用该默认 Python 直接跑 GPU 脚本时，才执行：'),
          mirrorLabel: en ? '🚀 China Mirror (NJU + Tsinghua TUNA)' : '🚀 国内镜像（南大 + 清华源，按需可选）',
          cmd: '"' + pyPath + '" -m pip install torch torchvision torchaudio -i https://mirror.nju.edu.cn/pytorch/whl/cu126 --extra-index-url https://pypi.tuna.tsinghua.edu.cn/simple'
        });
      } else {
        goods.push({
          level: 'green',
          title: en
            ? ('Probed Python PyTorch supports CUDA (' + s.torch.cudaRuntime + ') and is currently active')
            : ('本次检测的 Python 已装支持 CUDA (' + s.torch.cudaRuntime + ') 的 PyTorch 且当前可用'),
          note: en
            ? ('Probed path: ' + pyPath + ' | torch ' + s.torch.version + ' | CUDA Build: ' + s.torch.cudaRuntime + ' | Currently Available: True on ' + s.gpu + '. (Note: ComfyUI/Conda may use separate Python environments).')
            : ('实际检测路径：' + pyPath + '｜版本：' + s.torch.version + '｜支持 CUDA：是 (' + s.torch.cudaRuntime + ')｜当前能用 CUDA：是 (True)，可直接调用 ' + s.gpu + '。（注：ComfyUI 等工具可能使用其他独立 Python 环境）。')
        });
      }

      if (s.ramGB <= 16.5 && s.vramTotalMiB <= 8500) {
        issues.push({
          level: 'red',
          title: en ? '16 GB system RAM bottlenecks model CPU offloading' : '16GB 内存兜不住大模型的内存卸载',
          note: en ? '8 GB VRAM relies on system RAM for large diffusion/video models. 16 GB RAM leaves only ~7 GB free before heavy disk swapping.' : '8GB 显存跑生图或视频模型经常要借用系统内存，16GB 物理内存扣掉系统自用只剩七八个 G，借多了就会狂读硬盘卡死。'
        });
        topFixes.push({
          head: en ? 'Upgrade system RAM from 16 GB to 32 GB or 64 GB' : '把内存条从 16GB 升到 32GB 或 64GB',
          desc: en ? 'Laptop VRAM is soldered, but upgrading SODIMM RAM unlocks smooth CPU block-swapping for FLUX and 14B video models.' : '笔记本显存焊死改不了，但换两根 16G/32G 内存条就能打通 FLUX 和 14B 视频模型的 CPU 卸载通道。',
          cmd: ''
        });
      } else {
        goods.push({
          level: 'green',
          title: en ? ('System RAM is generous (' + s.ramGB + ' GB)') : ('系统内存容量充裕 (' + s.ramGB + 'GB)'),
          note: en ? 'Enough headroom for CPU block-swap offloading.' : '足够支撑大模型权重的 CPU 内存卸载（Block Swap）。'
        });
      }

      if (s.vramUsedMiB > 1400) {
        issues.push({
          level: 'amber',
          title: en ? ('Background apps are using ' + (s.vramUsedMiB / 1024).toFixed(2) + ' GB of VRAM') : ('桌面后台吃掉了 ' + (s.vramUsedMiB / 1024).toFixed(2) + 'GB 独立显存'),
          note: en ? ('Out of ' + s.vramTotalMiB + ' MiB total VRAM, only ' + s.vramFreeMiB + ' MiB is free. Video VAE decoding often OOMs because of this.') : ('总共 ' + s.vramTotalMiB + ' MiB 显存现在只剩 ' + s.vramFreeMiB + ' MiB，跑视频到最后一步 VAE 解码时最容易差这一口气。')
        });
        topFixes.push({
          head: en ? 'Free up background VRAM & unlock GPU power limit' : '跑大模型前清掉后台显存大户并切到高性能模式',
          desc: en ? 'Close Android emulators and browser hardware acceleration, and switch your laptop control center to Performance mode.' : '关掉安卓模拟器、多余浏览器网页的硬件加速，并在电脑控制中心切到狂暴/高性能模式解锁功耗墙。',
          cmd: ''
        });
      }

      const capNum = parseInt(String(s.gpuPowerCap).replace(/[^\d]/g, ''), 10);
      if (capNum > 0 && capNum <= 85) {
        issues.push({
          level: 'amber',
          title: en ? ('GPU power cap is currently limited to ' + s.gpuPowerCap) : ('显卡功耗上限目前锁在 ' + s.gpuPowerCap),
          note: en ? 'Plug in AC power and switch to Performance/Unleashed mode for sustained video generation.' : '处于偏保守的功耗档位，长时间跑视频生成建议插电并在自带控制中心切到性能/狂暴模式。'
        });
      }

      if (String(s.tools.nvcc).includes('Not')) {
        issues.push({
          level: 'amber',
          title: en ? 'No system-wide nvcc compiler (fine for normal inference)' : '没装系统级 nvcc 编译器（日常使用不用管）',
          note: en ? ('Your driver supports CUDA ' + s.cudaMax + '. You only need CUDA Toolkit if compiling custom kernels like FlashAttention from source.') : ('驱动已支持 CUDA ' + s.cudaMax + '，平时跑现成模型完全够用；只有自己从源码编译 FlashAttention 算子时才需要装 CUDA Toolkit。')
        });
      }

      if (!String(s.tools.conda).includes('Not') && !String(s.tools.code).includes('Not')) {
        goods.push({
          level: 'green',
          title: en ? 'Terminal PATH & dev toolchain are ready' : '终端 PATH 与开发工具链已就绪',
          note: en ? (s.tools.conda + ', VS Code (' + s.tools.code + '), and Git are all accessible globally.') : (s.tools.conda + '、VS Code (' + s.tools.code + ')、Git 等均可在终端直接调用。')
        });
      }

      const disks = s.disks || [];
      let biggestDisk = disks[0] || { Drive: 'C:', FreeGB: 0 };
      disks.forEach(d => { if (d.FreeGB > biggestDisk.FreeGB) biggestDisk = d; });
      if (biggestDisk.FreeGB >= 150) {
        goods.push({
          level: 'green',
          title: en ? ('Drive ' + biggestDisk.Drive + ' has ' + biggestDisk.FreeGB + ' GB free') : (biggestDisk.Drive + ' 盘还有 ' + biggestDisk.FreeGB + 'GB 空闲空间'),
          note: en ? 'Plenty of room for local checkpoints and video models.' : '足够放下多套生图与视频生成大模型。'
        });
      }

      return { issues, goods, topFixes };
    }

    function bindClueEvents() {
      const popover = document.getElementById('cluePopover');
      const popType = document.getElementById('popType');
      const popField = document.getElementById('popField');
      const popReason = document.getElementById('popReason');

      const TYPE_MAP = currentLang === 'en' ? {
        red: { text: '🔴 Bottleneck / Exposure', cls: 'pop-type type-red' },
        fact: { text: '⚪ Measured Hardware Fact', cls: 'pop-type type-fact' },
        infer: { text: '🟢 Usage Deduction', cls: 'pop-type type-infer' }
      } : {
        red: { text: '🔴 会卡住你的短板', cls: 'pop-type type-red' },
        fact: { text: '⚪ 机子实测数据', cls: 'pop-type type-fact' },
        infer: { text: '🟢 使用习惯侧写依据', cls: 'pop-type type-infer' }
      };

      function showPopover(target) {
        const t = target.getAttribute('data-type') || 'fact';
        const cfg = TYPE_MAP[t] || TYPE_MAP.fact;
        popType.className = cfg.cls;
        const pinHint = currentLang === 'en' ? (pinnedClue === target ? 'Pinned' : 'Click to pin') : (pinnedClue === target ? '已固定' : '点按可固定');
        popType.innerHTML = `<span>${cfg.text}</span><span style="font-weight:400;opacity:0.7;">${pinHint}</span>`;
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
    }

    const toast = document.getElementById('toast');
    let toastTimer = null;
    function showToast(msg) {
      toast.textContent = msg;
      toast.classList.add('show');
      clearTimeout(toastTimer);
      toastTimer = setTimeout(() => toast.classList.remove('show'), 2400);
    }

    function renderAll() {
      const en = (currentLang === 'en');
      document.documentElement.lang = en ? 'en' : 'zh-CN';
      document.getElementById('btnLangZh').classList.toggle('active', !en);
      document.getElementById('btnLangEn').classList.toggle('active', en);

      updateAntiDemoClock();

      document.getElementById('uiBrandBadge').textContent = en ? 'XunyiJu · AI PC Capability Audit' : '寻祎居 · 算力底牌侧写';
      document.getElementById('uiBrandTitle').textContent = en ? 'Who Are You · Your PC in the Eyes of AI' : '你是谁 · AI 眼里的这台电脑';
      document.getElementById('uiBrandSub').textContent = en ? ('Offline Read-Only Audit · PS ' + SNAPSHOT.psVersion) : ('零联网本地只读扫描 · PS ' + SNAPSHOT.psVersion);

      document.getElementById('uiLegendBar').innerHTML = en ? `
        <span class="legend-item"><span class="legend-red-dot"></span>Red: Bottleneck</span>
        <span class="legend-item"><span class="legend-white-fact"></span>White: Measured Fact</span>
        <span class="legend-item"><span class="legend-green-dash"></span>Green: Deduction (Hover/Click)</span>
      ` : `
        <span class="legend-item"><span class="legend-red-dot"></span>红点：会卡住你的短板</span>
        <span class="legend-item"><span class="legend-white-fact"></span>白字：机子实测数据</span>
        <span class="legend-item"><span class="legend-green-dash"></span>绿虚线：使用习惯侧写（悬停或点按看依据）</span>
      `;

      document.getElementById('uiLeftTitle').textContent = en ? '“Your PC in the Eyes of AI Models”' : '「AI 模型眼里的你」';
      document.getElementById('uiFpLabel').textContent = en ? 'Hardware Fingerprint ID' : '本机特征指纹 ID';
      document.getElementById('uiFpTag').textContent = en ? 'Local Hash' : '本地生成';
      document.getElementById('uiProofTag').textContent = SNAPSHOT.liveProofId;
      document.getElementById('fpHashText').textContent = SNAPSHOT.fingerprintId;
      document.getElementById('fpSubText').textContent = en
        ? `Core: ${SNAPSHOT.cpu} · ${SNAPSHOT.gpu} (${Math.round(SNAPSHOT.vramTotalMiB/1024)}GB) · RAM ${Math.round(SNAPSHOT.ramGB)}GB`
        : `实测核心：${SNAPSHOT.cpu} · ${SNAPSHOT.gpu} (${Math.round(SNAPSHOT.vramTotalMiB/1024)}GB) · 内存 ${Math.round(SNAPSHOT.ramGB)}GB`;

      const st = SNAPSHOT.stageTimings || [];
      const stText = st.map(x => `${x.Stage}@${x.TimeAt}(${x.DurationMs}ms)`).join(' · ');
      document.getElementById('fpStageTimings').textContent = (en ? 'Probe Timeline: ' : '分阶段实测检索轨迹：') + stText;

      document.getElementById('uiDiffTitle').textContent = en ? 'Changes Since Last Scan' : '跟上回扫描比有什么变化';

      document.getElementById('btnCopyPortrait').textContent = en ? '📋 Copy Narrative' : '📋 复制这段侧写';
      document.getElementById('btnCopyJson').textContent = en ? '🧬 Export JSON' : '🧬 导出 JSON 快照';
      document.getElementById('btnToggleClues').textContent = expanded
        ? (en ? '🔼 Hide All Evidence' : '🔼 收起所有判断依据')
        : (en ? '💡 Expand All Evidence' : '💡 展开所有判断依据');
      document.getElementById('btnViewRaw').textContent = en ? '📄 View Raw Report.txt' : '📄 看原始 Report.txt';
      document.getElementById('btnCopyCmd').textContent = en ? '⚡ Copy Re-run Command' : '⚡ 复制重测命令';

      document.getElementById('uiRightTitle').textContent = en ? '“Bottleneck Diagnosis”' : '「破绽与卡点诊断」';
      document.getElementById('uiDiagCountText').textContent = en ? 'bottlenecks may slow you down' : '处地方可能卡住你';
      document.getElementById('uiPriorityTitle').textContent = en ? '🔥 Fix These First' : '🔥 先改这几项';
      document.getElementById('uiChecklistHeader').textContent = en ? 'Plain-Language Checklist' : '逐项大白话清单';
      document.getElementById('appendixSearch').placeholder = en ? 'Filter fields or values (e.g. cuda, vram, ram)...' : '搜字段或值 (比如 cuda, 显存, 内存)...';

      // Narrative
      const paragraphs = buildPortrait(SNAPSHOT, currentLang);
      const narrativeContainer = document.getElementById('narrativeContainer');
      narrativeContainer.innerHTML = '';
      paragraphs.forEach((html, idx) => {
        const p = document.createElement('p');
        p.className = 'narrative-p';
        const num = String(idx + 1).padStart(2, '0');
        p.innerHTML = `<span class="p-index">${num}</span>${html}`;
        narrativeContainer.appendChild(p);
      });
      bindClueEvents();

      // Diff
      const diffList = document.getElementById('diffList');
      const diffBadge = document.getElementById('diffBadge');
      diffList.innerHTML = '';
      if (PREV_SNAPSHOT && PREV_SNAPSHOT.timestamp) {
        const diffs = [];
        const vramDiff = SNAPSHOT.vramFreeMiB - (PREV_SNAPSHOT.vramFreeMiB || 0);
        if (Math.abs(vramDiff) >= 30) {
          diffs.push(en
            ? `Free VRAM ${vramDiff > 0 ? 'increased by ' + vramDiff : 'decreased by ' + Math.abs(vramDiff)} MiB (now ${SNAPSHOT.vramFreeMiB} MiB)`
            : `可用显存 ${vramDiff > 0 ? '增加了 ' + vramDiff : '减少了 ' + Math.abs(vramDiff)} MiB（当前 ${SNAPSHOT.vramFreeMiB} MiB）`);
        }
        if (SNAPSHOT.psVersion !== PREV_SNAPSHOT.psVersion && PREV_SNAPSHOT.psVersion) {
          diffs.push(en
            ? `PowerShell engine updated: ${PREV_SNAPSHOT.psVersion} → ${SNAPSHOT.psVersion}`
            : `PowerShell 终端引擎已升级：${PREV_SNAPSHOT.psVersion} → ${SNAPSHOT.psVersion}`);
        }
        if (SNAPSHOT.torch.cudaAvailable !== PREV_SNAPSHOT.torch?.cudaAvailable) {
          diffs.push(en
            ? `Global PyTorch CUDA status changed to: ${SNAPSHOT.torch.cudaAvailable}`
            : `全局 PyTorch CUDA 可用性变为：${SNAPSHOT.torch.cudaAvailable}`);
        }
        if (diffs.length === 0) {
          diffs.push(en
            ? `Core hardware & toolchain match previous scan (${PREV_SNAPSHOT.timestamp.split(' ')[1]})`
            : `核心硬件与工具链状态与上次（${PREV_SNAPSHOT.timestamp.split(' ')[1]}）一致`);
          diffBadge.textContent = en ? 'Stable' : '状态稳定';
        } else {
          diffBadge.textContent = en ? `${diffs.length} change(s)` : `${diffs.length} 处变化`;
        }
        diffs.forEach(d => {
          const li = document.createElement('li');
          li.innerHTML = `<span class="diff-plus">~</span><span>${d}</span>`;
          diffList.appendChild(li);
        });
      } else {
        diffBadge.textContent = en ? 'Baseline Saved' : '基准已建立';
        const li = document.createElement('li');
        li.innerHTML = `<span class="diff-plus">+</span><span>${en ? 'Snapshot saved. Next run will automatically compare changes.' : '已保存本次扫描快照，下次双击运行会自动对比变化'}</span>`;
        diffList.appendChild(li);
      }

      // Diagnosis
      const diag = buildDiagnosis(SNAPSHOT, currentLang);
      const redCount = diag.issues.filter(i => i.level === 'red').length;
      const amberCount = diag.issues.filter(i => i.level === 'amber').length;
      const greenCount = diag.goods.length;

      document.getElementById('diagBigNum').textContent = diag.issues.length;
      document.getElementById('gradeBadge').textContent = redCount === 0
        ? (en ? 'Grade A · Ready' : 'A 满血就绪级')
        : redCount <= 2
          ? (en ? 'Grade B+ · Capped' : 'B+ 甜点受限级')
          : (en ? 'Grade C · Needs Fix' : 'C 亟待排障级');

      document.getElementById('segmentBar').innerHTML = `
        <div class="seg-red" style="flex:${Math.max(1, redCount)}"></div>
        <div class="seg-amber" style="flex:${Math.max(1, amberCount)}"></div>
        <div class="seg-green" style="flex:${Math.max(2, greenCount)}"></div>
      `;
      document.getElementById('segmentLabels').innerHTML = en ? `
        <span>🔴 ${redCount} Critical</span>
        <span>🟡 ${amberCount} Capped</span>
        <span>🟢 ${greenCount} Healthy</span>
      ` : `
        <span>🔴 ${redCount} 处立刻卡脖子</span>
        <span>🟡 ${amberCount} 处跑大模型受限</span>
        <span>🟢 ${greenCount} 项健康就绪</span>
      `;

      const priorityList = document.getElementById('priorityList');
      priorityList.innerHTML = '';
      document.getElementById('priorityTag').textContent = `TOP ${diag.topFixes.length}`;
      diag.topFixes.forEach((f, i) => {
        const li = document.createElement('li');
        li.className = 'priority-item';
        let cmdHtml = '';
        if (f.cmd) {
          const copyBtnText = en ? '📋 Copy Command' : '📋 复制国内镜像命令';
          const badgeText = f.mirrorLabel || (en ? 'Domestic Mirror' : '国内镜像');
          cmdHtml = `
            <div class="priority-cmd-wrap">
              <div class="priority-cmd-top">
                <span class="mirror-badge">${badgeText}</span>
                <button type="button" class="cmd-copy-btn" data-cmd="${f.cmd.replace(/"/g, '&quot;')}">${copyBtnText}</button>
              </div>
              <div class="priority-cmd">${f.cmd}</div>
            </div>
          `;
        }
        li.innerHTML = '<div class="priority-item-head">' + (i + 1) + '. ' + f.head + '</div><div class="priority-item-desc">' + f.desc + '</div>' + cmdHtml;
        priorityList.appendChild(li);
      });

      priorityList.querySelectorAll('.cmd-copy-btn').forEach(btn => {
        btn.addEventListener('click', e => {
          const c = e.currentTarget.getAttribute('data-cmd');
          navigator.clipboard.writeText(c).then(() => {
            showToast(en ? '✅ Copied domestic mirror command' : '✅ 已复制国内镜像安装命令');
          });
        });
      });

      const checklistContainer = document.getElementById('checklistContainer');
      checklistContainer.innerHTML = '';
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

      // Appendix
      const appendixItems = [
        { k: en ? "Scan Started At" : "本次检索启动时间", v: SNAPSHOT.scanStartTimestamp, status: "ok" },
        { k: en ? "Result Retrieved At" : "检索出结果时间", v: `${SNAPSHOT.timestamp} (耗时 ${SNAPSHOT.scanDurationMs} ms)`, status: "ok" },
        { k: en ? "Anti-Demo Proof ID" : "防套壳真机校验码", v: SNAPSHOT.liveProofId, status: "ok" },
        { k: en ? "Brand & Model" : "电脑品牌与型号", v: `${SNAPSHOT.brand} ${SNAPSHOT.model}`, status: "" },
        { k: en ? "Motherboard & BIOS" : "主板与 BIOS", v: `${SNAPSHOT.board} / BIOS ${SNAPSHOT.bios}`, status: "" },
        { k: en ? "Operating System" : "操作系统", v: `${SNAPSHOT.os} (Build ${SNAPSHOT.osBuild})`, status: "" },
        { k: en ? "PowerShell Engine" : "PowerShell 终端版本", v: `PowerShell ${SNAPSHOT.psVersion}`, status: "ok" },
        { k: en ? "Processor (CPU)" : "处理器 (CPU)", v: `${SNAPSHOT.cpu} (${SNAPSHOT.cpuCores}C/${SNAPSHOT.cpuThreads}T)`, status: "ok" },
        { k: en ? "Physical RAM" : "物理内存总量", v: `${SNAPSHOT.ramGB} GB (${SNAPSHOT.ramModules})`, status: SNAPSHOT.ramGB <= 16.5 ? "warn" : "ok" },
        { k: en ? "Discrete GPU" : "独立显卡 (GPU)", v: SNAPSHOT.gpu, status: "ok" },
        { k: en ? "Dedicated VRAM" : "专用显存 (VRAM)", v: `Total ${SNAPSHOT.vramTotalMiB} MiB / Used ${SNAPSHOT.vramUsedMiB} MiB / Free ${SNAPSHOT.vramFreeMiB} MiB`, status: SNAPSHOT.vramFreeMiB < 6500 ? "warn" : "ok" },
        { k: en ? "NVIDIA Driver & Max CUDA" : "NVIDIA 驱动与最高 CUDA", v: `Driver ${SNAPSHOT.nvDriver} / CUDA ${SNAPSHOT.cudaMax}`, status: "ok" },
        { k: en ? "GPU Power & Temp" : "显卡功耗与温度", v: `${SNAPSHOT.gpuPowerDraw} / ${SNAPSHOT.gpuPowerCap} | ${SNAPSHOT.gpuTemp} (${SNAPSHOT.gpuPerfState})`, status: "" },
        ...SNAPSHOT.disks.map(d => ({ k: en ? `Disk ${d.Drive} Space` : `磁盘 ${d.Drive} 容量`, v: `Total ${d.TotalGB} GB / Free ${d.FreeGB} GB`, status: d.FreeGB > 200 ? "ok" : d.FreeGB < 50 ? "warn" : "" })),
        { k: en ? "Probed Default Python" : "全局 Python 版本", v: SNAPSHOT.tools.python, status: "ok" },
        { k: en ? "Actual Probed Python Path" : "实际检测的 Python 路径", v: SNAPSHOT.torch.pythonPath || 'Not Found', status: "ok" },
        { k: en ? "PyTorch Supports CUDA (Build)" : "PyTorch 构建是否支持 CUDA", v: (SNAPSHOT.torch.version === 'not_installed' || SNAPSHOT.torch.version === 'Not Installed') ? (en ? 'PyTorch Not Installed' : '未安装 PyTorch') : ((SNAPSHOT.torch.cudaBuilt === 'True' || (SNAPSHOT.torch.cudaRuntime && SNAPSHOT.torch.cudaRuntime !== 'None')) ? (en ? `Yes (${SNAPSHOT.torch.version}, CUDA ${SNAPSHOT.torch.cudaRuntime} build)` : `支持 (${SNAPSHOT.torch.version}, 内置 CUDA ${SNAPSHOT.torch.cudaRuntime})`) : (en ? `No (${SNAPSHOT.torch.version}, CPU-only build)` : `不支持 (${SNAPSHOT.torch.version}, 纯 CPU 构建版)`)), status: (SNAPSHOT.torch.cudaBuilt === 'True' || (SNAPSHOT.torch.cudaRuntime && SNAPSHOT.torch.cudaRuntime !== 'None')) ? "ok" : "warn" },
        { k: en ? "CUDA Currently Usable (Runtime)" : "当前能否调用 CUDA (Runtime)", v: SNAPSHOT.torch.cudaAvailable === 'True' ? (en ? 'True (Currently Active)' : 'True (当前可用)') : (en ? 'False (Currently Unavailable)' : 'False (当前不可用)'), status: SNAPSHOT.torch.cudaAvailable === 'True' ? "ok" : "warn" },
        { k: en ? "Conda & Envs Count" : "Conda 状态与环境数", v: `${SNAPSHOT.tools.conda} (${SNAPSHOT.condaEnvs.length} envs)`, status: "ok" },
        { k: en ? "Conda Environments" : "Conda 环境列表", v: SNAPSHOT.condaEnvs.join(', ') || 'None', status: "" },
        { k: "uv / Git", v: `${SNAPSHOT.tools.uv} / ${SNAPSHOT.tools.git}`, status: "ok" },
        { k: "Node.js / pnpm", v: `${SNAPSHOT.tools.node} / pnpm ${SNAPSHOT.tools.pnpm}`, status: "ok" },
        { k: "VS Code CLI (code)", v: SNAPSHOT.tools.code, status: "ok" },
        { k: "Rust / .NET / Docker", v: `${SNAPSHOT.tools.rust} | .NET ${SNAPSHOT.tools.dotnet} | ${SNAPSHOT.tools.docker}`, status: "" },
        { k: "FFmpeg / nvcc", v: `FFmpeg: ${SNAPSHOT.tools.ffmpeg} | nvcc: ${SNAPSHOT.tools.nvcc}`, status: "" }
      ];

      document.getElementById('appendixTitle').textContent = en
        ? `All Probed Fields & Values (Technical Appendix · ${appendixItems.length} items)`
        : `全部探测项和读到的值（底层技术附录 · 共 ${appendixItems.length} 项）`;

      const appendixGrid = document.getElementById('appendixGrid');
      const kw = (document.getElementById('appendixSearch').value || '').trim().toLowerCase();
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

    document.getElementById('btnLangZh').addEventListener('click', () => { currentLang = 'zh'; expanded = false; renderAll(); });
    document.getElementById('btnLangEn').addEventListener('click', () => { currentLang = 'en'; expanded = false; renderAll(); });
    document.getElementById('appendixSearch').addEventListener('input', () => renderAll());

    document.addEventListener('click', () => {
      if (pinnedClue) {
        pinnedClue.classList.remove('active');
        pinnedClue = null;
        document.getElementById('cluePopover').classList.remove('visible');
      }
    });

    document.getElementById('btnCopyPortrait').addEventListener('click', () => {
      const text = Array.from(document.querySelectorAll('.narrative-p')).map(p => p.innerText.replace(/\s+/g, ' ').trim()).join('\n\n');
      navigator.clipboard.writeText(`【XunyiJu AI PC Portrait (${SNAPSHOT.fingerprintId} | ${SNAPSHOT.liveProofId} | ${SNAPSHOT.timestamp})】\n\n${text}`).then(() => {
        showToast(currentLang === 'en' ? '✅ Copied 7-paragraph portrait' : '✅ 已复制 7 段侧写（含防套壳时间戳）');
      });
    });

    document.getElementById('btnCopyJson').addEventListener('click', () => {
      navigator.clipboard.writeText(JSON.stringify(SNAPSHOT, null, 2)).then(() => {
        showToast(currentLang === 'en' ? '🧬 Copied JSON snapshot' : '🧬 已复制 JSON 快照');
      });
    });

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
      e.currentTarget.textContent = expanded
        ? (currentLang === 'en' ? '🔼 Hide All Evidence' : '🔼 收起所有判断依据')
        : (currentLang === 'en' ? '💡 Expand All Evidence' : '💡 展开所有判断依据');
    });

    const rawModal = document.getElementById('rawModal');
    document.getElementById('rawReportContent').textContent = RAW_REPORT_TEXT;
    document.getElementById('btnViewRaw').addEventListener('click', () => rawModal.classList.add('open'));
    document.getElementById('btnCloseModal').addEventListener('click', () => rawModal.classList.remove('open'));
    rawModal.addEventListener('click', e => { if (e.target === rawModal) rawModal.classList.remove('open'); });

    document.getElementById('btnCopyCmd').addEventListener('click', () => {
      navigator.clipboard.writeText('pwsh -NoProfile -ExecutionPolicy Bypass -File .\\AI_PC_Environment_Audit.ps1').then(() => {
        showToast(currentLang === 'en' ? '⚡ Copied PowerShell 7 command' : '⚡ 已复制 PowerShell 7 重测命令');
      });
    });

    renderAll();
  </script>
</body>
</html>
'@

$finalHtml = $htmlTemplate.Replace('__SNAPSHOT_JSON__', $snapshotJsonStr).Replace('__PREV_JSON__', $prevJsonStr).Replace('__RAW_REPORT_JSON__', $rawReportEscaped)
[System.IO.File]::WriteAllText($htmlPath, $finalHtml, $utf8Bom)

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
if ($isEn) {
    Write-Host " Audit Complete! (PowerShell $($PSVersionTable.PSVersion) | Elapsed: $totalElapsedMs ms)" -ForegroundColor Green
    Write-Host " Live Proof ID        : $liveProofId" -ForegroundColor Green
    Write-Host " 1. Portrait Webpage  : $htmlPath" -ForegroundColor Green
    Write-Host " 2. Raw Text Report   : $reportPath" -ForegroundColor Green
} else {
    Write-Host " 扫描完成！(PowerShell $($PSVersionTable.PSVersion) | 实测耗时: $totalElapsedMs ms)" -ForegroundColor Green
    Write-Host " 防套壳真机校验码   : $liveProofId" -ForegroundColor Green
    Write-Host " 1. 可视化侧写网页 : $htmlPath" -ForegroundColor Green
    Write-Host " 2. 原始文本报告   : $reportPath" -ForegroundColor Green
}
Write-Host "==================================================================" -ForegroundColor Green

if (-not $NoOpenBrowser) {
    try { Start-Process $htmlPath } catch {}
}
