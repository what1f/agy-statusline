[CmdletBinding()]
param(
    [switch]$FromSource,
    [string]$Version = 'latest',
    [switch]$Yes,
    [switch]$NoConfig,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

if ($Help) {
    @'
Install agy-statusline for Antigravity CLI on Windows.

Usage:
  install.ps1 [options]

Options:
  -FromSource       Build from local source using zig instead of downloading a release
  -Version <tag>    Install a specific release tag (default: latest)
  -Yes              Overwrite existing statusLine in settings.json without prompting
  -NoConfig         Install binary only; do not modify settings.json
  -Help             Show this help
'@
    exit 0
}

$Repo = if ($env:AGY_STATUSLINE_REPO) { $env:AGY_STATUSLINE_REPO } else { 'what1f/agy-statusline' }
$DefaultAgyHome = Join-Path $env:USERPROFILE '.gemini\antigravity-cli'
$AgyHome = if ($env:AGY_HOME) { $env:AGY_HOME } else { $DefaultAgyHome }
$DestBin = Join-Path $AgyHome 'statusline.exe'
$SettingsPath = Join-Path $AgyHome 'settings.json'

if (-not $Yes -and $env:AGY_STATUSLINE_YES -eq '1') {
    $Yes = $true
}

function Get-TargetArch {
    $rawArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch -Regex ($rawArch) {
        '^(ARM64|AARCH64)$' { return 'aarch64-windows' }
        '^(AMD64|X86_64|X64)$' { return 'x86_64-windows' }
        default { throw "Unsupported Windows architecture: $rawArch" }
    }
}

function Invoke-SourceBuild([string]$OutPrefix) {
    if (-not (Test-Path 'build.zig')) {
        throw 'build.zig not found in current directory. Clone the repository first or omit -FromSource.'
    }
    if (-not (Get-Command zig -ErrorAction SilentlyContinue)) {
        throw 'zig is required for -FromSource.'
    }
    Write-Host 'Building agy-statusline from source...'
    & zig build -Doptimize=ReleaseFast --prefix $OutPrefix
    if ($LASTEXITCODE -ne 0) {
        throw "zig build failed with exit code $LASTEXITCODE"
    }
}

function Resolve-CommandPath([string]$Value) {
    $expanded = $Value.Trim()
    if ($expanded.StartsWith('~/') -or $expanded.StartsWith('~\')) {
        $expanded = Join-Path $env:USERPROFILE $expanded.Substring(2)
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($expanded)
    try {
        return [System.IO.Path]::GetFullPath($expanded).TrimEnd('\', '/').ToLowerInvariant()
    } catch {
        return $expanded.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
    }
}

$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("agy-statusline-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

try {
    $BuiltBin = $null
    if ($FromSource) {
        $OutPrefix = Join-Path $TmpDir 'out'
        Invoke-SourceBuild $OutPrefix
        $BuiltBin = Join-Path $OutPrefix 'bin\statusline.exe'
    } else {
        $Target = Get-TargetArch
        $ArchiveName = "agy-statusline-$Target.zip"
        $BaseUrl = if ($Version -eq 'latest') {
            "https://github.com/$Repo/releases/latest/download"
        } else {
            "https://github.com/$Repo/releases/download/$Version"
        }
        $ArchivePath = Join-Path $TmpDir $ArchiveName
        $SumsPath = Join-Path $TmpDir 'checksums.txt'

        Write-Host "Downloading $ArchiveName ($Version)..."
        $downloaded = $false
        try {
            Invoke-WebRequest -Uri "$BaseUrl/$ArchiveName" -OutFile $ArchivePath -UseBasicParsing
            $downloaded = $true
        } catch {
            if ((Test-Path 'build.zig') -and (Get-Command zig -ErrorAction SilentlyContinue)) {
                Write-Host 'Release download unavailable; falling back to local source build...'
                $OutPrefix = Join-Path $TmpDir 'out'
                Invoke-SourceBuild $OutPrefix
                $BuiltBin = Join-Path $OutPrefix 'bin\statusline.exe'
            } else {
                throw "Failed to download $BaseUrl/$ArchiveName : $($_.Exception.Message)"
            }
        }

        if ($downloaded) {
            try {
                Invoke-WebRequest -Uri "$BaseUrl/checksums.txt" -OutFile $SumsPath -UseBasicParsing
                $line = Get-Content -Path $SumsPath | Where-Object { $_ -match ("\s+\*?" + [regex]::Escape($ArchiveName) + '$') } | Select-Object -First 1
                if ($line) {
                    $expected = ($line -split '\s+')[0].ToLowerInvariant()
                    $actual = (Get-FileHash -Path $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
                    if ($actual -ne $expected) {
                        throw "Checksum mismatch for $ArchiveName"
                    }
                }
            } catch {
                if ($_.Exception.Message -like 'Checksum mismatch*') {
                    throw
                }
            }
            $ExtractDir = Join-Path $TmpDir 'extract'
            Expand-Archive -Path $ArchivePath -DestinationPath $ExtractDir -Force
            $BuiltBin = Join-Path $ExtractDir 'statusline.exe'
        }
    }

    if (-not $BuiltBin -or -not (Test-Path $BuiltBin)) {
        throw "Installed binary not found at $BuiltBin"
    }

    New-Item -ItemType Directory -Path $AgyHome -Force | Out-Null
    $StageBin = "$DestBin.tmp.$PID"
    Copy-Item -Path $BuiltBin -Destination $StageBin -Force
    Move-Item -Path $StageBin -Destination $DestBin -Force
    Write-Host "Installed binary to $DestBin"

    if ($NoConfig) {
        return
    }

    $CommandValue = if ((Resolve-CommandPath $AgyHome) -eq (Resolve-CommandPath $DefaultAgyHome)) {
        '~/.gemini/antigravity-cli/statusline.exe'
    } else {
        $DestBin
    }

    $Data = [ordered]@{}
    if (Test-Path $SettingsPath) {
        $raw = [System.IO.File]::ReadAllText($SettingsPath, [System.Text.UTF8Encoding]::new($false)).Trim()
        if ($raw) {
            try {
                $parsed = $raw | ConvertFrom-Json
            } catch {
                Write-Warning "Could not parse $SettingsPath; skipped automatic update."
                Write-Host "Configure manually inside Antigravity CLI:"
                Write-Host "  /statusline $CommandValue"
                return
            }
            if ($null -eq $parsed -or $parsed -is [System.Array] -or $parsed -isnot [PSCustomObject]) {
                Write-Warning "settings.json root is not a JSON object; skipped automatic update."
                Write-Host "Configure manually inside Antigravity CLI:"
                Write-Host "  /statusline $CommandValue"
                return
            }
            foreach ($prop in $parsed.PSObject.Properties) {
                $Data[$prop.Name] = $prop.Value
            }
        }
    }

    $shouldWrite = $true
    if ($Data.Contains('statusLine') -and $null -ne $Data['statusLine']) {
        $existing = $Data['statusLine']
        $isSame = $false
        if ($existing -is [PSCustomObject]) {
            $exType = if ($existing.PSObject.Properties['type']) { $existing.type } else { 'command' }
            $exCmd = if ($existing.PSObject.Properties['command']) { [string]$existing.command } else { '' }
            $exEnabled = if ($existing.PSObject.Properties['enabled']) { $existing.enabled } else { $true }
            if ($exType -eq 'command' -and $exCmd -and ((Resolve-CommandPath $exCmd) -eq (Resolve-CommandPath $DestBin)) -and ($exEnabled -ne $false)) {
                $isSame = $true
            }
        }

        if ($isSame) {
            Write-Host "statusLine is already configured in $SettingsPath"
            return
        }

        $existingJson = $existing | ConvertTo-Json -Compress -Depth 32
        if ($Yes) {
            $shouldWrite = $true
        } elseif ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
            Write-Host "Existing statusLine found in $SettingsPath`:"
            Write-Host "  $existingJson"
            $answer = Read-Host 'Overwrite existing statusLine configuration? [y/N]'
            if ($answer -notmatch '^(y|yes)$') {
                $shouldWrite = $false
                Write-Host 'Kept existing settings.json unchanged.'
                Write-Host 'To switch later, run inside Antigravity CLI:'
                Write-Host "  /statusline $CommandValue"
            }
        } else {
            $shouldWrite = $false
            Write-Host "Existing statusLine found in $SettingsPath`: $existingJson"
            Write-Host 'Skipped overwriting in non-interactive mode. Re-run with -Yes or run inside Antigravity CLI:'
            Write-Host "  /statusline $CommandValue"
        }
    }

    if ($shouldWrite) {
        $Data['statusLine'] = [ordered]@{
            type    = 'command'
            command = $CommandValue
        }
        $jsonText = ($Data | ConvertTo-Json -Depth 32) + "`n"
        $tmpSettings = "$SettingsPath.tmp.$PID"
        [System.IO.File]::WriteAllText($tmpSettings, $jsonText, [System.Text.UTF8Encoding]::new($false))
        Move-Item -Path $tmpSettings -Destination $SettingsPath -Force
        Write-Host "Configured statusLine in $SettingsPath"
    }
} finally {
    if (Test-Path $TmpDir) {
        Remove-Item -Path $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
