param([string]$AppPath)
$ErrorActionPreference='Stop'
# Shadow the cmdlet so any accidental runtime dependency fails.
function global:Get-FileHash { throw 'Get-FileHash deliberately unavailable in this regression' }
. (Join-Path $AppPath 'Downloader.Core.ps1')
$work=Join-Path $PSScriptRoot ('work/hash-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$passed=0
function Assert($value,[string]$label){if(-not $value){throw "FAIL $label"};$script:passed++;Write-Host "PASS $label"}
$file=Join-Path $work 'Unicode tiếng Việt [abc].bin'
[IO.File]::WriteAllBytes($file,[byte[]]@())
Assert ((Get-FileSha256 -LiteralPath $file) -eq 'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855') 'SHA256 empty file without Get-FileHash'
[IO.File]::WriteAllBytes($file,[Text.Encoding]::ASCII.GetBytes('abc'))
Assert ((Get-FileSha256 -LiteralPath $file) -eq 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD') 'SHA256 known vector and literal Unicode bracket path'
Push-Location $work
try{Assert ((Get-FileSha256 -LiteralPath ([IO.Path]::GetFileName($file))) -eq 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD') 'Relative paths resolve against PowerShell location'}finally{Pop-Location}
$handle=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$handle.Dispose()
Assert $true 'Hash closes file handle after success'
$rejected=$false;try{$null=Get-FileSha256 -LiteralPath (Join-Path $work 'missing')}catch{$rejected=$true}
Assert $rejected 'Missing files fail instead of bypassing checksum'
$zip=Join-Path $work 'media.zip'
$package=New-CapCutInputZip $zip (Join-Path $PSScriptRoot 'work/fixtures/fixture-video.mp4') (Join-Path $PSScriptRoot 'work/fixtures/fixture-audio.m4a')
Assert ([IO.File]::Exists($package.Path) -and -not $package.Reused) 'CapCut ZIP creation works without Get-FileHash'
$package=New-CapCutInputZip $zip (Join-Path $PSScriptRoot 'work/fixtures/fixture-video.mp4') (Join-Path $PSScriptRoot 'work/fixtures/fixture-audio.m4a')
Assert $package.Reused 'ZIP verification and reuse work without Get-FileHash'
Remove-Item Function:Get-FileSha256
. (Join-Path $AppPath 'AppUpdate.Core.ps1')
Assert ((Get-FileSha256 -LiteralPath $file) -eq 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD') 'Updater loads its own hash helper from shared core'
$stage=Join-Path $work 'stage/Bilibili-Downloader'
$target=Join-Path $work 'installed'
foreach($name in Get-AppRuntimeFiles){
    foreach($base in @($stage,$target)){
        $destination=Join-Path $base $name
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        [IO.File]::Copy((Join-Path $AppPath $name),$destination)
    }
}
[IO.File]::WriteAllText((Join-Path $stage 'VERSION.txt'),'9.0.0')
[IO.File]::WriteAllText((Join-Path $target 'VERSION.txt'),'2.4.0')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$updateZip=Join-Path $work 'update.zip'
[IO.Compression.ZipFile]::CreateFromDirectory((Split-Path $stage),$updateZip)
$rejected=$false
try{$null=Install-AppPackage $target $updateZip ('0'*64) '9.0.0'}catch{$rejected=$_.Exception.Message -match 'SHA-256'}
Assert ($rejected -and (Get-Content -LiteralPath (Join-Path $target 'VERSION.txt')) -eq '2.4.0') 'Updater still rejects bad checksums without Get-FileHash'
$result=Install-AppPackage $target $updateZip (Get-FileSha256 -LiteralPath $updateZip) '9.0.0'
Assert ($result.Updated -and (Test-VocalPackage $target)) 'Combined update verifies and installs without Get-FileHash'
$child=Join-Path $work 'setup-without-hash.ps1'
$childCode=@'
param([string]$AppPath)
function global:Get-FileHash { throw 'Get-FileHash unavailable' }
& (Join-Path $AppPath 'Start-Bilibili-Download.ps1') -SetupOnly
exit $LASTEXITCODE
'@
[IO.File]::WriteAllText($child,$childCode,(New-Object Text.UTF8Encoding($true)))
$winps=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
& $winps -NoProfile -ExecutionPolicy Bypass -File $child -AppPath $AppPath
Assert ($LASTEXITCODE -eq 0) 'Actual tooling preflight succeeds with Get-FileHash disabled'
Write-Host "TOTAL PASS $passed"
