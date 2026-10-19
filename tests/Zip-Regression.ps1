param([string]$AppPath)
$ErrorActionPreference='Stop'
. (Join-Path $AppPath 'Downloader.Core.ps1')
$testDir=Join-Path $PSScriptRoot ('work/zip-tests-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDir)
$passed=0
function Assert($condition,[string]$label){if(-not $condition){throw "FAIL $label"};$script:passed++;Write-Host "PASS $label"}
try{
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
$record=Get-DownloadRecordPath (Join-Path $testDir 'app-work') $testDir 'thử nghiệm'
Write-AtomicJson $record @{identity='original-video';video=@{complete=$true;length=123}}
Assert ((Read-SharedJson $record).video.complete -and (Split-Path $record -Parent) -eq (Join-Path $testDir 'app-work/download-records')) 'Identity retained internally for reusing completed media'
Assert ($record -ne (Get-DownloadRecordPath (Join-Path $testDir 'app-work') (Join-Path $testDir 'another-output') 'thử nghiệm')) 'Same name in different output folders has a separate identity'
$parts=@(foreach($track in @('_video.mp4','_audio.m4a')){foreach($suffix in @('.part','.part.aria2','.native','.native.part','.native.ytdl','.curl.part')){Join-Path $testDir ('thử nghiệm'+$track+$suffix)}})
foreach($path in $parts){[IO.File]::WriteAllText($path,'leftover')}
$otherJob=Join-Path $testDir 'other_video.mp4.part';[IO.File]::WriteAllText($otherJob,'resume')
$unrelated=Join-Path $testDir 'notes.part';[IO.File]::WriteAllText($unrelated,'keep')
$beforeMedia=@((Get-FileSha256 $video),(Get-FileSha256 $audio),(Get-FileSha256 $target))
Remove-CompletedDownloadParts $testDir 'thử nghiệm'
Assert (@($parts | Where-Object {Test-Path -LiteralPath $_}).Count -eq 0) 'Completed job clears checkpoints from every download transport'
Assert ((Test-Path -LiteralPath $otherJob) -and (Test-Path -LiteralPath $unrelated)) 'Cleanup preserves unrelated files and resumable jobs'
Assert (($beforeMedia -join '|') -eq (@((Get-FileSha256 $video),(Get-FileSha256 $audio),(Get-FileSha256 $target)) -join '|')) 'Cleanup preserves final video audio and ZIP bytes'
$rejected=$false
try{Remove-CompletedDownloadParts $testDir '../other'}catch{$rejected=$true}
Assert $rejected 'Cleanup rejects names that escape the output folder'
$lockPath=Join-Path $testDir 'job.download.lock'
$jobLock=Open-DownloadOutputLock $lockPath
try{
    $rejected=$false
    try{$otherLock=Open-DownloadOutputLock $lockPath;$otherLock.Dispose()}catch{$rejected=$true}
    Assert $rejected 'Active job lock rejects a second downloader'
}finally{$jobLock.Dispose()}
Assert (-not (Test-Path -LiteralPath $lockPath)) 'Operating system removes released job lock'
@{status='PASS';passed=$passed}|ConvertTo-Json -Compress
}finally{
    $resolved=[IO.Path]::GetFullPath($testDir)
    $allowed=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'work'))+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected test cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
