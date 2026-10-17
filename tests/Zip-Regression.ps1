param([string]$AppPath)
$ErrorActionPreference='Stop'
. (Join-Path $AppPath 'Downloader.Core.ps1')
$testDir=Join-Path $PSScriptRoot ('work/zip-tests-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDir)
$passed=0
function Assert($condition,[string]$label){if(-not $condition){throw "FAIL $label"};$script:passed++;Write-Host "PASS $label"}
$video=Join-Path $testDir 'thử nghiệm_video.mp4'
$audio=Join-Path $testDir 'thử nghiệm_audio.m4a'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'work/fixtures/fixture-video.mp4') -Destination $video
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'work/fixtures/fixture-audio.m4a') -Destination $audio
$target=Join-Path $testDir 'thử nghiệmstage1.zip'
$package=New-CapCutInputZip $target $video $audio
Assert ((Test-Path -LiteralPath $target) -and -not $package.Reused) 'Create archive after both files exist'
$zip=[IO.Compression.ZipFile]::OpenRead($target)
try{Assert ($zip.Entries.Count -eq 2 -and $zip.GetEntry('thử nghiệm_video.mp4') -and $zip.GetEntry('thử nghiệm_audio.m4a')) 'Exactly one video and one audio with Unicode original names at archive root'}finally{$zip.Dispose()}
$oldHash=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
$reused=New-CapCutInputZip $target $video $audio
Assert ($reused.Reused -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $oldHash) 'Matching archive reused without rewriting'
$stream=[IO.File]::OpenWrite($audio)
try{$stream.Position=10;$stream.WriteByte(123)}finally{$stream.Dispose()}
$rejected=$false
try{$null=New-CapCutInputZip $target $video $audio}catch{$rejected=$true}
Assert ($rejected -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $oldHash) 'Different same-length content cannot overwrite an existing archive'
$missingZip=Join-Path $testDir 'missing.zip'
$rejected=$false
try{$null=New-CapCutInputZip $missingZip $video (Join-Path $testDir 'missing.m4a')}catch{$rejected=$true}
Assert ($rejected -and -not (Test-Path -LiteralPath $missingZip)) 'Missing audio never produces a final ZIP'
$empty=Join-Path $testDir 'empty.m4a';[IO.File]::WriteAllBytes($empty,[byte[]]@())
$rejected=$false
try{$null=New-CapCutInputZip $missingZip $video $empty}catch{$rejected=$true}
Assert ($rejected -and -not (Test-Path -LiteralPath $missingZip)) 'Empty audio never produces a final ZIP'
Assert (@(Get-ChildItem -LiteralPath $testDir -Filter '*.tmp' -File).Count -eq 0) 'No unfinished ZIP is published or left after successful packaging'
@{status='PASS';passed=$passed;package=$target}|ConvertTo-Json -Compress
