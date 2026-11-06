[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $repoRoot "src"
$netServicePath = "src/ReplicatedStorage/Gaxia_Packages/Shared/NetService.lua"
$trapPath = "src/ServerStorage/Gaxia_Packages_Server/AntiCheat/RemoteTrap.lua"
$inboundPattern = "FireServer\(|InvokeServer\(|OnServerEvent\s*:Connect|OnServerInvoke\s*="
$pathSeparators = [char[]]@([char]'\', [char]'/')

if (-not (Test-Path -LiteralPath $sourceRoot)) {
    throw "Source root not found: $sourceRoot"
}

$violations = [System.Collections.Generic.List[string]]::new()
$sourceFiles = & rg --files $sourceRoot -g "*.lua" -g "*.luau"
if ($LASTEXITCODE -ne 0) {
    throw "rg --files failed with exit code $LASTEXITCODE"
}

foreach ($sourceFile in $sourceFiles) {
    $absolutePath = if ([System.IO.Path]::IsPathRooted($sourceFile)) {
        $sourceFile
    }
    else {
        Join-Path $repoRoot $sourceFile
    }
    $normalizedRoot = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd($pathSeparators)
    $normalizedAbsolutePath = [System.IO.Path]::GetFullPath($absolutePath)
    if (-not $normalizedAbsolutePath.StartsWith($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Source file is outside the repository: $absolutePath"
    }
    $relativePath = $normalizedAbsolutePath.Substring($normalizedRoot.Length).TrimStart($pathSeparators).Replace("\", "/")
    $lineNumber = 0

    foreach ($line in Get-Content -LiteralPath $absolutePath -ErrorAction Stop) {
        $lineNumber += 1
        # This intentionally ignores line comments. The policy concerns source
        # execution paths, not historical documentation or examples.
        $code = $line -replace "--.*$", ""
        if ($code -notmatch $inboundPattern) {
            continue
        }

        $isNetService = $relativePath -eq $netServicePath
        $isTrapListener = $relativePath -eq $trapPath -and $code -match "OnServerEvent\s*:Connect"
        if (-not $isNetService -and -not $isTrapListener) {
            $violations.Add("${relativePath}:${lineNumber}: $line")
        }
    }
}

if ($violations.Count -gt 0) {
    Write-Output "[REMOTE_SURFACE_AUDIT] Unexpected client-to-server transport API:"
    $violations | ForEach-Object { Write-Output "  $_" }
    exit 1
}

Write-Output "[REMOTE_SURFACE_AUDIT] PASS - NetService owns C2S transport; RemoteTrap is the sole reviewed listener exception."
