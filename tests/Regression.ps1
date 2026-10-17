param([string]$AppPath)
$ErrorActionPreference='Stop'
. (Join-Path $AppPath 'Downloader.Core.ps1')
$testDir=Join-Path $PSScriptRoot 'work/core-results'
[void][IO.Directory]::CreateDirectory($testDir)
$passed=0
function Assert($value,[string]$label){if(-not $value){throw "FAIL $label"};Write-Host "PASS $label";$script:passed++}
Assert ((ConvertTo-BilibiliUrl 'https://www.bilibili.com/video/BV1nZaf6nEFb/?share_source=x&p=2') -eq 'https://www.bilibili.com/video/BV1nZaf6nEFb/?p=2') 'Canonical URL preserves selected part'
foreach($url in @('https://bilibili.com.evil/video/BV1a/','https://www.bilibili.com/video/BV1a/?p=0','https://acdn.bravedown.com/download?token=a')){$rejected=$false;try{$null=ConvertTo-BilibiliUrl $url}catch{$rejected=$true};Assert $rejected 'Invalid input rejected'}
Assert ((ConvertTo-SafeFileName 'CON') -eq '_CON') 'Windows reserved name'
Assert ((ConvertTo-SafeFileName 'thử nghiệm 中文 100%') -eq 'thử nghiệm 中文 100%') 'Unicode and percent filename preserved'
$inputFile=Join-Path $testDir 'mirrors.txt'
Write-AriaInput $inputFile @('https://example.com/video?a=1','https://example.net/video?a=2') 'thử nghiệm 中文.mp4.part'
$inputText=[IO.File]::ReadAllText($inputFile)
Assert ($inputText -eq "https://example.com/video?a=1`thttps://example.net/video?a=2`n  out=thử nghiệm 中文.mp4.part`n") 'Aria mirror input contract UTF8 TAB and indented out'
Assert ((Get-DownloadErrorHint 'getaddrinfo failed') -match 'DNS') 'DNS classification'
Assert ((Get-DownloadErrorHint 'HTTP 403 Forbidden') -match 'từ chối') '403 classification'
Assert ((Protect-DownloadLog 'GET https://cdn.test/v?token=secret&deadline=123') -notmatch 'secret') 'Signed token hidden in log'
$originalError='Exception: [AbstractCommand.cc:351] errorCode=22 URI=https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/81/73/40468287381/40468287381-1-30064.m4s?token=secret | status=567 | [SocketCore.cc:886] errorCode=1 Failed to receive data, cause: Error: The handle specified is invalid.'
Assert ((Get-DownloadErrorHint $originalError) -match 'HTTP 567' -and (Get-DownloadErrorHint $originalError) -notmatch 'không tìm thấy tài nguyên') 'Reported 567 never misclassified from 404 inside media ID'
foreach($code in @(401,403,404,429)){
    Assert (@(Get-DownloadHttpStatuses "URI=https://cdn.test/401403404429567.m4s?x=404 | status=$code") -contains $code) "Parse actual HTTP status $code"
}
Assert (@(Get-DownloadHttpStatuses 'URI=https://cdn.test/401403404429567.m4s?x=404 | [Source.cc:403] errorCode=22').Count -eq 0) 'URL and source line numbers are not HTTP statuses'
Assert ((Get-DownloadErrorHint 'status=404') -match 'HTTP 404') 'Actual 404 classified'
Assert ((Get-DownloadErrorHint 'HTTP Error 429: Too Many Requests') -match 'HTTP 429') 'yt-dlp HTTP error classified'
Assert ((Get-DownloadErrorHint '[SocketCore.cc:886] errorCode=1 Failed to receive data, cause: Error: The handle specified is invalid.') -match 'socket/TLS') 'Socket failure distinct from disk failure'
Assert ((Get-DownloadErrorHint 'status=503') -match '5xx') 'Generic CDN 5xx classified'
Assert ((Get-DownloadErrorHint 'Network problem has occurred. An attempt was made to access a socket in a way forbidden by its access permissions.') -notmatch 'Máy chủ từ chối') 'Local socket permission error is not HTTP Forbidden'
$protected=Protect-DownloadLog $originalError
Assert ((Protect-DownloadLog $protected) -eq $protected) 'Signed query redaction is idempotent across worker and GUI'
$mockFormat=[pscustomobject]@{url='https://primary.test/v?token=primary'}
$mockSession=[pscustomobject]@{Dashes=@([pscustomobject]@{video=@([pscustomobject]@{baseUrl=$mockFormat.url;backupUrl=@('https://backup.test/v?token=backup')});audio=@()})}
$mirrorUrls=@(Get-TrackUrls $mockSession $mockFormat)
Assert ($mirrorUrls.Count -eq 2 -and $mirrorUrls[0] -eq $mockFormat.url -and $mirrorUrls[1] -match 'backup.test') 'Primary CDN first and backup URL preserved'
$guiTokens=$null;$guiErrors=$null
$guiAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $AppPath 'Start-GUI.ps1'),[ref]$guiTokens,[ref]$guiErrors)
Assert (@($guiErrors).Count -eq 0) 'GUI syntax valid'
$logFn=$guiAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Add-Log'},$true)
Invoke-Expression $logFn.Extent.Text
$logBox=[pscustomobject]@{Text='';TextLength=0;SelectionStart=0}
$logBox | Add-Member ScriptMethod AppendText {param($text) $this.Text+=$text;$this.TextLength=$this.Text.Length}
$logBox | Add-Member ScriptMethod ScrollToCaret {}
$script:lastLogText=''
Add-Log $originalError
Add-Log (Protect-DownloadLog $originalError)
Assert ($logBox.Text.Split([char]10).Count -eq 2 -and $logBox.Text -notmatch 'token=secret') 'Duplicate console/state errors logged once with token hidden'
foreach($controlName in @('urlBox','nameBox','folderBox','browseButton','getQualityButton','updateButton','appUpdateButton','vocalButton','qualityBox','downloadButton','openFolderButton','stopButton')){
    Set-Variable -Name $controlName -Value ([pscustomobject]@{Enabled=$true;Text=''})
}
foreach($functionName in @('Set-UiBusy','Reset-CompletedDownload')){
    $uiFn=$guiAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $functionName},$true)
    Invoke-Expression $uiFn.Extent.Text
}
$script:worker=$null;$script:choices=@('720p');$script:downloadComplete=$true;$script:completedDirectory='F:\CapCut-Automation\inbox'
Set-UiBusy $false
Assert (-not $downloadButton.Enabled -and $downloadButton.Text -eq 'Đã tải xong' -and $openFolderButton.Enabled) 'Completion locks download and exposes saved files'
Set-UiBusy $true
Assert (-not $downloadButton.Enabled -and -not $openFolderButton.Enabled) 'Busy state never opens completed output'
$script:worker=[pscustomobject]@{Id=1}
Reset-CompletedDownload
Assert $script:downloadComplete 'Busy worker cannot lose its completion state through input events'
$script:worker=$null
Reset-CompletedDownload
Assert (-not $script:downloadComplete -and $downloadButton.Enabled -and -not $openFolderButton.Enabled -and $script:completedDirectory -eq '') 'Changed selection enables a new download and clears old output'
$script:choices=@()
Reset-CompletedDownload
Assert (-not $downloadButton.Enabled) 'Changed URL without quality cannot start a download'
$script:vocalWorker=[pscustomobject]@{HasExited=$false}
Set-UiBusy $false
Assert (-not $appUpdateButton.Enabled -and -not $vocalButton.Enabled) 'Vocal window blocks updating and duplicate launch'
$script:vocalWorker=$null
$state=Join-Path $testDir 'state.json'
Write-AtomicJson $state @{message='中文 tiếng Việt';percent=1}
Assert ((Read-SharedJson $state).message -eq '中文 tiếng Việt') 'Shared UTF8 JSON round trip'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $AppPath 'Start-Bilibili-Download.ps1'),[ref]$tokens,[ref]$errors)
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-DownloaderState'},$true)
Invoke-Expression $fn.Extent.Text
$StateFile=$state;$script:stateWarningShown=$false
$exclusive=[IO.File]::Open($state,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{Set-DownloaderState 'downloading' 'locked-state regression' 43;Assert $true 'Locked status file does not interrupt worker'}finally{$exclusive.Dispose()}
$writerPath=Join-Path $testDir 'writer.ps1'
[IO.File]::WriteAllText($writerPath,'. (Join-Path $args[0] "Downloader.Core.ps1");$ErrorActionPreference="Stop";for($i=0;$i -lt 200;$i++){Write-AtomicJson $args[1] @{percent=$i % 100;message="test"};Start-Sleep -Milliseconds 3}')
$psi=New-Object Diagnostics.ProcessStartInfo
$psi.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$psi.Arguments=(@('-NoProfile','-File',$writerPath,$AppPath,$state)|ForEach-Object{Quote-ProcessArgument $_}) -join ' '
$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
$writer=New-Object Diagnostics.Process;$writer.StartInfo=$psi;[void]$writer.Start()
$stdoutTask=$writer.StandardOutput.ReadToEndAsync();$stderrTask=$writer.StandardError.ReadToEndAsync()
$reads=0;$invalid=0
while(-not $writer.HasExited){try{$record=Read-SharedJson $state;if($record.percent -lt 0 -or $record.percent -ge 100){$invalid++};$reads++}catch{$invalid++};Start-Sleep -Milliseconds 3}
$writer.WaitForExit();$writerError=$stderrTask.GetAwaiter().GetResult();Assert ($writer.ExitCode -eq 0 -and $invalid -eq 0 -and $reads -gt 20) "Concurrent state snapshots valid ($reads reads); $writerError";$writer.Dispose()
$child=Join-Path $testDir 'flood.ps1'
[IO.File]::WriteAllText($child,'[Console]::OutputEncoding=[Text.Encoding]::UTF8;for($i=0;$i -lt 500;$i++){[Console]::Out.WriteLine("stdout $i");[Console]::Error.WriteLine("stderr $i")};exit 7')
$counters=@{stdout=0;stderr=0}
$process=Invoke-DownloaderProcess -Executable (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -Arguments @('-NoProfile','-File',$child) -Directory $testDir -TimeoutSeconds 30 -OnLine {param($line) if($line -match '^stdout'){$counters.stdout++};if($line -match '^stderr'){$counters.stderr++}}
Assert ($process.ExitCode -eq 7 -and $counters.stdout -eq 500 -and $counters.stderr -eq 500) 'Both child pipes drained and exact exit code retained'
$video=Test-DownloadedTrack (Join-Path $PSScriptRoot 'work/fixtures/fixture-video.mp4') 'video' 720
$audio=Test-DownloadedTrack (Join-Path $PSScriptRoot 'work/fixtures/fixture-audio.m4a') 'audio'
Assert ($video.AudioTracks -eq 0 -and $audio.VideoTracks -eq 0 -and [Math]::Abs($video.Duration-$audio.Duration) -lt 1) 'Existing P1 stream separation resolution and durations'
$bad=Join-Path $testDir 'truncated.mp4';[IO.File]::WriteAllBytes($bad,[byte[]](0,0,0,64,109,100,97,116,0,0,0,0))
$rejected=$false;try{$null=Test-DownloadedTrack $bad 'video'}catch{$rejected=$true};Assert $rejected 'Truncated media rejected'
$qualityFn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-QualityChoices'},$true)
Invoke-Expression $qualityFn.Extent.Text
$fakeInfo=[pscustomobject]@{formats=@(
    [pscustomobject]@{height=720;fps=30;vcodec='avc1';acodec='none';ext='mp4';url='https://cdn/v720';tbr=10;format_id='720'},
    [pscustomobject]@{height=2160;fps=30;vcodec='avc1';acodec='none';ext='mp4';url='https://cdn/v2160';tbr=20;format_id='2160'},
    [pscustomobject]@{height=1080;fps=30;vcodec='avc1';acodec='none';ext='mp4';url='https://cdn/v1080';tbr=15;format_id='1080'})}
$qualityList=@(Get-QualityChoices $fakeInfo)
Assert ($qualityList[0].Height -eq 2160 -and $qualityList[1].Height -eq 1080 -and $qualityList[2].Height -eq 720) 'Highest available height selected without fixed maximum'
Write-Host "TOTAL PASS $passed"
