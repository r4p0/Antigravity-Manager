# Antigravity Headless 一键安装脚本 (Windows 服务器)
#
# 用法：
#   irm https://raw.githubusercontent.com/lbjlaq/Antigravity-Manager/main/install-headless.ps1 | iex
#
# 本脚本只做：下载官方 headless 包 -> 校验 -> 解压 -> 放置 -> 打印启动说明。
# 不注册系统服务、不写注册表。服务生命周期由使用者自行管理。
#
# 参数：
#   -Version      指定版本（默认最新 release）
#   -InstallDir   安装目录，默认 $env:LOCALAPPDATA\AntigravityServer
#   -DryRun       只打印操作
#   -AssetDir     本地资产目录（测试用），含 headless 包

param(
    [string]$Version = "",
    [string]$InstallDir = "",
    [switch]$DryRun,
    [string]$AssetDir = ""
)

$ErrorActionPreference = "Stop"
$Repo = "lbjlaq/Antigravity-Manager"
$GithubApi = "https://api.github.com/repos/$Repo/releases"
$SCRIPT_VERSION = "1.0.0"
$ProgressPreference = 'SilentlyContinue'
$script:ReleaseVersion = ""

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Join-Path $env:LOCALAPPDATA "AntigravityServer"
}

function Info    { Write-Host "[INFO] $args" -ForegroundColor Cyan }
function Success { Write-Host "[OK] $args" -ForegroundColor Green }
function Warn    { Write-Host "[WARN] $args" -ForegroundColor Yellow }
function Fail    { Write-Host "[ERROR] $args" -ForegroundColor Red; throw $args }

function Invoke-Step {
    param([scriptblock]$Action, [string]$Description)
    if ($DryRun) { Write-Host "[DRY-RUN] $Description" -ForegroundColor Yellow; return }
    return & $Action
}

function Detect-Platform {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -ne "AMD64") { Fail "本脚本仅支持 x64 (AMD64)，当前架构: $arch" }
    Info "检测到平台: Windows x64"
}

function Get-ReleaseVersion {
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $script:ReleaseVersion = $Version
        Info "使用指定版本: v$($script:ReleaseVersion)"
        return
    }
    Info "正在获取最新版本..."
    try {
        $release = Invoke-RestMethod -Uri "$GithubApi/latest" -Headers @{
            "User-Agent" = "Antigravity-Headless-Installer"
            "Accept"     = "application/vnd.github.v3+json"
        } -TimeoutSec 15
        $script:ReleaseVersion = $release.tag_name -replace "^v", ""
        if ($script:ReleaseVersion -match '^\d+\.\d+\.\d+') {
            Info "最新版本: v$($script:ReleaseVersion)"
            return
        }
    } catch {
        Warn "GitHub API 请求失败（可能限流），尝试 updater.json..."
    }
    try {
        $updater = Invoke-RestMethod -Uri "https://github.com/$Repo/releases/latest/download/updater.json" -TimeoutSec 15
        $script:ReleaseVersion = $updater.version -replace "^v", ""
        if ($script:ReleaseVersion -match '^\d+\.\d+\.\d+') {
            Info "最新版本（updater.json）: v$($script:ReleaseVersion)"
            return
        }
    } catch {
        Warn "updater.json 获取失败，尝试重定向方式..."
    }
    try {
        Invoke-WebRequest -Uri "https://github.com/$Repo/releases/latest" -MaximumRedirection 0 -ErrorAction SilentlyContinue -UseBasicParsing | Out-Null
    } catch {
        $location = $_.Exception.Response.Headers.Location
        if ($location -and $location -match "/tag/v?(.+)$") {
            $script:ReleaseVersion = $Matches[1]
            Info "最新版本（重定向）: v$($script:ReleaseVersion)"
            return
        }
    }
    Fail "无法确定版本，请显式指定: `$Version = `"5.0.4`""
}

function Download-File {
    param([string]$Url, [string]$Dest)
    if (-not [string]::IsNullOrWhiteSpace($AssetDir)) {
        $local = Join-Path $AssetDir ([System.IO.Path]::GetFileName($Dest))
        if (-not (Test-Path $local)) { Fail "AssetDir 中缺少文件: $local" }
        Info "使用本地资产: $local"
        Copy-Item -LiteralPath $local -Destination $Dest -Force
        return
    }
    if ($DryRun) {
        Write-Host "[DRY-RUN] Invoke-WebRequest -Uri $Url -OutFile $Dest" -ForegroundColor Yellow
        return
    }
    Info "下载: $Url"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 600
    } catch {
        Fail "下载失败: $Url`n$_"
    }
    if (-not (Test-Path $Dest)) { Fail "下载后文件不存在: $Dest" }
}

function Verify-Checksum {
    param([string]$Archive, [string]$ChecksumFile)
    if ($DryRun) { return }
    $expected = (Get-Content -LiteralPath $ChecksumFile -TotalCount 1).Split(' ')[0].ToLower()
    $actual = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { Fail "SHA256 校验失败: 期望 $expected，实际 $actual" }
    Success "SHA256 校验通过"
}

function Expand-Tarball {
    param([string]$Tarball, [string]$Dest)
    if ($DryRun) {
        Write-Host "[DRY-RUN] 解压 $Tarball 到 $Dest" -ForegroundColor Yellow
        return
    }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($tar) {
        & $tar.Source -xzf $Tarball -C $Dest
        if ($LASTEXITCODE -ne 0) { Fail "tar 解压失败" }
    } else {
        # 回退到 7-Zip
        $7z = (Get-Command 7z.exe, 7za.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $7z) { Fail "需要 tar.exe（Win10 1803+）或 7-Zip 来解压 .tar.gz" }
        & $7z x $Tarball "-o$Dest" -y | Out-Null
        & $7z x (Join-Path $Dest "dist-headless.tar") "-o$Dest" -y | Out-Null
    }
}

try {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "    Antigravity Headless Installer (Windows)" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    Detect-Platform
    Get-ReleaseVersion

    $base = "https://github.com/$Repo/releases/download/v$($script:ReleaseVersion)"
    $archive = "antigravity-server-windows-x64.tar.gz"
    $checksum = "$archive.sha256"

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ag-headless-" + [guid]::NewGuid().ToString("N"))
    if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $tempDir | Out-Null }

    try {
        $archivePath = Join-Path $tempDir $archive
        $checksumPath = Join-Path $tempDir $checksum
        Download-File -Url "$base/$archive" -Dest $archivePath
        Download-File -Url "$base/$checksum" -Dest $checksumPath
        Verify-Checksum -Archive $archivePath -ChecksumFile $checksumPath

        $src = Join-Path $tempDir "src"
        Expand-Tarball -Tarball $archivePath -Dest $src

        if (-not $DryRun) {
            if (-not (Test-Path (Join-Path $src "dist\index.html"))) { Fail "包中缺少 dist/index.html" }
            if (-not (Test-Path (Join-Path $src "antigravity-server.exe"))) { Fail "包中缺少 antigravity-server.exe" }
        }

        if (-not $DryRun) {
            New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
            $finalBin = Join-Path $InstallDir "antigravity-server.exe"
            try {
                Copy-Item -LiteralPath (Join-Path $src "antigravity-server.exe") -Destination $finalBin -Force
            } catch {
                Fail "复制二进制失败，可能 antigravity-server.exe 正在运行，请先停止进程: $_"
            }
            $distNew = Join-Path $InstallDir "dist.new"
            if (Test-Path $distNew) { Remove-Item -LiteralPath $distNew -Recurse -Force }
            Copy-Item -Path (Join-Path $src "dist\*") -Destination $distNew -Recurse -Force
            $distFinal = Join-Path $InstallDir "dist"
            if (Test-Path $distFinal) { Remove-Item -LiteralPath $distFinal -Recurse -Force }
            Move-Item -LiteralPath $distNew -Destination $distFinal
            Set-Content -LiteralPath (Join-Path $InstallDir "VERSION") -Value $script:ReleaseVersion -Encoding ASCII
        } else {
            Write-Host "[DRY-RUN] 放置文件到 $InstallDir" -ForegroundColor Yellow
        }

        Write-Host ""
        Success "文件已安装到: $InstallDir"
        Write-Host ""
        Write-Host "===== 启动说明 =====" -ForegroundColor Cyan
        Write-Host "1) WebUI + API 模式（默认监听 0.0.0.0:8045）："
        Write-Host "   `$env:ABV_API_KEY = `"your-key`""
        Write-Host "   `$env:ABV_DATA_DIR = `"$InstallDir\data`""
        Write-Host "   & `"$InstallDir\antigravity-server.exe`" -p 8045"
        Write-Host ""
        Write-Host "2) 纯代理模式：`$env:ABV_API_KEY=`"your-key`"; & `"$InstallDir\antigravity-server.exe`" --no-web -p 8045"
        Write-Host ""
        Write-Host "3) 安全提示："
        Write-Host "   - headless 默认绑定 0.0.0.0，生产环境务必设置 ABV_API_KEY"
        Write-Host "   - 仅本机访问请加: `$env:ABV_BIND_LOCAL_ONLY = 1"
        Write-Host "   - 强制指定 WebUI 资源: `$env:ABV_DIST_PATH = `"$InstallDir\dist`""
        Write-Host "   - 接口: OpenAI 兼容 /v1 ；Anthropic /v1/messages"
        Write-Host ""
        Write-Host "4) 服务生命周期请自行管理（NSSM / 任务计划等），本脚本不注册服务。"
        Write-Host "   许可证: CC BY-NC-SA 4.0，仅限非商业用途。"
        Write-Host "==================" -ForegroundColor Cyan
    } finally {
        if (-not $DryRun -and (Test-Path $tempDir)) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} catch {
    Write-Host "[FATAL] $_" -ForegroundColor Red
    exit 1
}
exit 0
