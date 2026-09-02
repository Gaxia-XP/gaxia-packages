$repoRoot = Split-Path -Parent $PSScriptRoot
$activeStudio = @(Get-Process -Name RobloxStudioBeta -ErrorAction SilentlyContinue)

if ($activeStudio.Count -gt 0) {
    throw "Roblox Studio is already running. Close it before this isolated smoke test so --quitAfterExecution cannot affect active work."
}

$candidateRoots = @(
    (Join-Path $env:LOCALAPPDATA "Froststrap\Versions"),
    (Join-Path $env:LOCALAPPDATA "Roblox\Versions")
)

$studio = $candidateRoots |
    Where-Object { Test-Path -LiteralPath $_ } |
    ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter RobloxStudioBeta.exe -Recurse -File } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1

if ($null -eq $studio) {
    throw "RobloxStudioBeta.exe was not found under Froststrap or Roblox Versions."
}

$tempRoot = [System.IO.Path]::GetTempPath()
$tempDir = Join-Path $tempRoot ("gaxia-oss-smoke-" + [guid]::NewGuid().ToString("N"))
$placePath = Join-Path $tempDir "gaxia-oss-smoke.rbxlx"
$outputPath = Join-Path $tempDir "studio-output.log"
$testScript = Join-Path $repoRoot "tests\oss_dependencies.smoke.luau"

New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    Push-Location $repoRoot
    try {
        $promiseSource = Join-Path $repoRoot "src\ReplicatedStorage\Gaxia_Packages\Shared\Promise.lua"
        $promiseBlob = (& git hash-object -- $promiseSource).Trim()
        if ($LASTEXITCODE -ne 0 -or $promiseBlob -ne "dc82ad5682221814ee58daa89b31e30f31a87ebd") {
            throw "Gaxia.Promise no longer matches the approved upstream compatibility snapshot."
        }

        & wally install
        if ($LASTEXITCODE -ne 0) {
            throw "wally install failed with exit code $LASTEXITCODE"
        }

        $profileStoreSource = Join-Path $repoRoot "ServerPackages\_Index\lm-loleris_profilestore@1.0.3\profilestore\ProfileStore.luau"
        $profileStoreBlob = (& git hash-object -- $profileStoreSource).Trim()
        if ($LASTEXITCODE -ne 0 -or $profileStoreBlob -ne "5b196af86a1eafa2ad5e94ef9398c483e87704ed") {
            throw "ProfileStore package no longer matches the reviewed upstream source."
        }

        & rojo build default.project.json --output $placePath
        if ($LASTEXITCODE -ne 0) {
            throw "rojo build failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }

    $studioArguments = @(
        "--task", "RunScript",
        "--localPlaceFile", $placePath,
        "--runScriptFile", $testScript,
        "--outputFile", $outputPath,
        "--quitAfterExecution"
    )
    $studioProcess = Start-Process -FilePath $studio.FullName -ArgumentList $studioArguments -Wait -PassThru -WindowStyle Hidden
    $studioExit = $studioProcess.ExitCode

    $studioOutput = if (Test-Path -LiteralPath $outputPath) {
        Get-Content -LiteralPath $outputPath -Raw
    }
    else {
        ""
    }

    if ($studioExit -ne 0) {
        Write-Output $studioOutput
        throw "Roblox Studio smoke test exited with code $studioExit"
    }

    if (-not $studioOutput.Contains("[OSS_SMOKE] PASS")) {
        Write-Output $studioOutput
        throw "Roblox Studio output did not contain the success marker."
    }

    Write-Output "[OSS_SMOKE] PASS"
}
finally {
    $resolvedTemp = [System.IO.Path]::GetFullPath($tempDir)
    $resolvedRoot = [System.IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTemp.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTemp).StartsWith("gaxia-oss-smoke-")) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
