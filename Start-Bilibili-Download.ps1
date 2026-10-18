param(
    [Parameter(Position = 0)][string]$Url,
    [string]$VideoFormatId, [string]$FileName, [string]$OutputDirectory, [string]$StateFile,
    [switch]$SetupOnly, [switch]$InspectOnly, [switch]$ListQualities, [switch]$UpdateTools, [switch]$UpdateApp,
    [switch]$OpenVocal, [string]$VocalInput
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$Root = $PSScriptRoot
$Tools = Join-Path $Root 'tools'
$Work = Join-Path $Root 'work'
. (Join-Path $Root 'Downloader.Core.ps1')
[void][IO.Directory]::CreateDirectory($Tools)
[void][IO.Directory]::CreateDirectory($Work)
$script:stateWarningShown = $false
$destinationLock = $null
$scratch = $null
$applicationLock = $null

function Set-DownloaderState {
    param([string]$Status, [string]$Message, [int]$Percent = 0, $Choices = $null)
    if($Message -ne $script:lastConsoleMessage){Write-Host $Message;$script:lastConsoleMessage=$Message}
    if ([string]::IsNullOrWhiteSpace($StateFile)) { return }
    try {
        Write-AtomicJson $StateFile @{status=$Status; message=$Message; percent=[Math]::Max(0,[Math]::Min(100,$Percent)); choices=$Choices; updated=[DateTime]::UtcNow.ToString('o')}
    } catch {
        # A busy status file must NEVER interrupt the media download.
        if (-not $script:stateWarningShown) { Write-Warning 'Không cập nhật được bảng tiến độ; tiến trình tải vẫn tiếp tục. Xem Hoạt động.'; $script:stateWarningShown=$true }
    }
}
function Receive-ToolFile([string]$Address, [string]$Path) {
    for ($attempt=0; $attempt -lt 3; $attempt++) {
        try { Invoke-WebRequest -UseBasicParsing -Uri $Address -OutFile $Path -TimeoutSec 90; return }
        catch { if($attempt -eq 2){throw}; Start-Sleep -Seconds 2 }
    }
}
function Get-Tooling {
    $yt = Join-Path $Tools 'yt-dlp.exe'
    $sum = Join-Path $Tools 'SHA2-256SUMS'
    $valid = $false
    if ((Test-Path -LiteralPath $yt) -and (Test-Path -LiteralPath $sum)) {
        $line=Get-Content -LiteralPath $sum | Where-Object {$_ -match '\s+yt-dlp\.exe$'} | Select-Object -First 1
        if($line){$expected=($line.Trim() -split '\s+')[0];$valid=(Get-FileSha256 -LiteralPath $yt) -eq $expected}
    }
    $setupLock = $null
    $aria=Get-ChildItem -LiteralPath $Tools -Filter aria2c.exe -File -Recurse | Select-Object -First 1
    try {
        if(-not $valid -or $UpdateTools -or -not $aria){
            for($lockAttempt=0;$lockAttempt -lt 100;$lockAttempt++){
                try{$setupLock=[IO.File]::Open((Join-Path $Tools 'setup.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);break}
                catch [IO.IOException]{if($lockAttempt -eq 99){throw 'Một cửa sổ khác đang cài/cập nhật công cụ. Đợi tác vụ đó rồi thử lại.'};Start-Sleep -Milliseconds 200}
            }
        }
        if(-not $valid -or $UpdateTools){
            Set-DownloaderState 'working' 'Đang lấy và kiểm tra yt-dlp từ GitHub chính thức...'
            $release=Invoke-RestMethod -Uri 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest' -Headers @{'User-Agent'='Bilibili-Downloader'} -TimeoutSec 30
            $base='https://github.com/yt-dlp/yt-dlp/releases/download/'+$release.tag_name+'/'
            $tempYt=Join-Path $Work ('yt-dlp.'+$PID+'.exe')
            $tempSum=Join-Path $Work ('SHA2-256SUMS.'+$PID)
            try{
                Receive-ToolFile ($base+'yt-dlp.exe') $tempYt
                Receive-ToolFile ($base+'SHA2-256SUMS') $tempSum
                $line=Get-Content -LiteralPath $tempSum | Where-Object {$_ -match '\s+yt-dlp\.exe$'} | Select-Object -First 1
                if(-not $line -or (Get-FileSha256 -LiteralPath $tempYt) -ne ($line.Trim() -split '\s+')[0]){throw 'SHA-256 yt-dlp không khớp; giữ nguyên công cụ cũ. Thử cập nhật lại.'}
                Copy-Item -LiteralPath $tempYt -Destination $yt -Force
                Copy-Item -LiteralPath $tempSum -Destination $sum -Force
            }finally{foreach($p in @($tempYt,$tempSum)){Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue}}
        }
        $aria=Get-ChildItem -LiteralPath $Tools -Filter aria2c.exe -File -Recurse | Select-Object -First 1
        if(-not $aria){
            Set-DownloaderState 'working' 'Đang lấy aria2 portable từ GitHub chính thức...'
            $release=Invoke-RestMethod -Uri 'https://api.github.com/repos/aria2/aria2/releases/latest' -Headers @{'User-Agent'='Bilibili-Downloader'} -TimeoutSec 30
            $asset=$release.assets | Where-Object {$_.name -match '^aria2-.*win-64bit.*\.zip$'} | Select-Object -First 1
            if(-not $asset){throw 'Không tìm được aria2 Windows 64-bit trên GitHub.'}
            $zip=Join-Path $Work ('aria2.'+$PID+'.zip')
            try{
                Receive-ToolFile $asset.browser_download_url $zip
                if($asset.digest -and $asset.digest -match '^sha256:(.+)$' -and (Get-FileSha256 -LiteralPath $zip) -ne $Matches[1]){throw 'Mã SHA-256 aria2 không khớp.'}
                Expand-Archive -LiteralPath $zip -DestinationPath $Tools -Force
            }finally{Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue}
            $aria=Get-ChildItem -LiteralPath $Tools -Filter aria2c.exe -File -Recurse | Select-Object -First 1
        }
        if(-not $aria){throw 'Không tìm thấy aria2c.exe sau khi cài đặt.'}
        foreach($exe in @($yt,$aria.FullName)){
            $check=Invoke-DownloaderProcess -Executable $exe -Arguments @('--version') -Directory $Root -TimeoutSeconds 30
            if($check.ExitCode -ne 0){throw "Công cụ không chạy được: $([IO.Path]::GetFileName($exe)). Bấm Cập nhật công cụ hoặc cài lại."}
            if($check.StdOut.Count){Write-Host $check.StdOut[0]}
        }
        return [pscustomobject]@{YtDlp=$yt;Aria2=$aria.FullName}
    }finally{if($setupLock){$setupLock.Dispose()}}
}
function Get-BilibiliSession {
    Set-DownloaderState 'working' 'Đang lấy thông tin và URL tải mới từ Bilibili...' $script:overallPercent
    $folder=Join-Path $scratch ([Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($folder)
    $result=Invoke-DownloaderProcess -Executable $bin.YtDlp -Directory $folder -TimeoutSeconds 180 -Arguments @('--ignore-config','--no-playlist','--no-warnings','--socket-timeout','30','--extractor-retries','3','--dump-single-json','--write-pages',$Url)
    if($result.ExitCode -ne 0){
        $detail=Protect-DownloadLog (@($result.StdErr | Select-Object -Last 4) -join ' | ')
        $hint=Get-DownloadErrorHint $detail
        throw "Không lấy được video (yt-dlp $($result.ExitCode)): $hint Chi tiết: $detail"
    }
    $info=($result.StdOut -join "`n") | ConvertFrom-Json
    if(-not $info.formats){throw 'Bilibili không trả về luồng video. Kiểm tra quyền truy cập và phần p trong link.'}
    $dashes=@(foreach($dump in Get-ChildItem -LiteralPath $folder -Filter '*playurl*.dump' -File){
        try{$page=Read-SharedJson $dump.FullName;if($page.data.dash){$page.data.dash}elseif($page.result.dash){$page.result.dash}}catch{}
    })
    return [pscustomobject]@{Info=$info;Dashes=$dashes}
}
function Get-QualityChoices($Info){
    return @($Info.formats | Where-Object {$_.height -and $_.vcodec -ne 'none' -and $_.ext -eq 'mp4' -and $_.acodec -eq 'none' -and $_.url} |
        Group-Object height | ForEach-Object{
            $best=$_.Group | Sort-Object @{Expression='fps';Descending=$true},@{Expression={if($_.vcodec -match '^avc1'){1}else{0}};Descending=$true},@{Expression='tbr';Descending=$true} | Select-Object -First 1
            $codec=switch -Regex ($best.vcodec){'^avc1'{'H.264'} '^hev1|^hvc1'{'HEVC'} '^av01'{'AV1'} default{$best.vcodec}}
            [pscustomobject]@{Height=[int]$best.height;Format=$best;Label=("{0}p | {1} fps | {2}" -f $best.height,$best.fps,$codec);Codec=$codec}
        } | Sort-Object Height -Descending)
}
function Save-Manifest { Write-AtomicJson $manifestPath $manifest }
function Complete-Track([string]$Path,[string]$Target,[string]$Kind,[int]$Height,$Format){
    if(-not (Test-Path -LiteralPath $Path)){throw 'Công cụ báo xong nhưng không có đúng tệp đích; tác vụ chưa hoàn tất.'}
    if($Format.filesize -and (Get-Item -LiteralPath $Path).Length -ne [long]$Format.filesize){throw 'Dung lượng thực tế không khớp dung lượng máy chủ; giữ tệp dở.'}
    $media=Test-DownloadedTrack $Path $Kind $Height $expectedDuration
    $manifest[$Kind]=@{complete=$true;length=(Get-Item -LiteralPath $Path).Length;duration=$media.Duration;height=$media.Height}
    Save-Manifest
    [IO.File]::Move($Path,$Target)
    return $media
}
function Download-NativeTrack($CurrentSession,$Format,[string]$TrackUrl,[string]$Target,[string]$Kind){
    # aria2 .part files may have holes. Never hand their apparent file length to a
    # sequential downloader. Native uses its own resumable .native.part instead.
    $nativePath="$Target.native"
    if(Test-Path -LiteralPath $nativePath){return [pscustomobject]@{ExitCode=0;Path=$nativePath;Details=''}}
    $nativeFormat=$Format.PSObject.Copy()
    $nativeFormat.url=$TrackUrl
    $nativeInfo=@{id=$CurrentSession.Info.id;title=$CurrentSession.Info.title;ext=$Format.ext;formats=@($nativeFormat);http_headers=$CurrentSession.Info.http_headers}
    $infoPath=Join-Path $scratch ($Kind+'.native.json')
    Write-AtomicJson $infoPath $nativeInfo
    $phase=if($Kind -eq 'video'){'video'}else{'âm thanh'}
    Set-DownloaderState 'downloading' ("Chuyển sang HTTP của yt-dlp cho {0}; giữ nguyên phần aria2 và dùng checkpoint riêng..." -f $phase) $script:overallPercent
    $nativeLines=New-Object 'Collections.Generic.List[string]'
    $nativeErrors=New-Object 'Collections.Generic.List[string]'
    $nativeProgress=@{last=[DateTime]::MinValue;percent=-1}
    $onNativeLine={param($line)
        $safe=Protect-DownloadLog $line
        if($nativeLines.Count -ge 12){$nativeLines.RemoveAt(0)};[void]$nativeLines.Add($safe)
        if($line -match 'ERROR:|Exception:|ThrottledDownload|HTTP Error|Permission denied|Access is denied'){
            if($nativeErrors.Count -ge 6){$nativeErrors.RemoveAt(0)};[void]$nativeErrors.Add($safe)
        }
        if($line -match '^\[download\]\s+(\d+(?:\.\d+)?)%'){
            $percent=[Math]::Min(100,[int][Math]::Floor([double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)))
            if($percent -eq $nativeProgress.percent -and ([DateTime]::UtcNow-$nativeProgress.last).TotalSeconds -lt 1){return}
            $nativeProgress.percent=$percent;$nativeProgress.last=[DateTime]::UtcNow
            $script:overallPercent=if($Kind -eq 'video'){[int]($percent*0.9)}else{90+[int]($percent*0.09)}
            Set-DownloaderState 'downloading' ("HTTP {0}: {1}" -f $phase,($safe -replace '^\[download\]\s*','')) $script:overallPercent
        }
    }
    # A slow but live transfer is not a failure. Socket timeout still handles stalls.
    $nativeArgs=@('--ignore-config','--no-cache-dir','--no-playlist','--no-warnings','--downloader','native','--load-info-json',$infoPath,'--format',[string]$Format.format_id,'--output',$nativePath,'--continue','--fixup','never','--no-mtime','--newline','--progress','--progress-delta','1','--socket-timeout','20','--retries','1','--retry-sleep','http:2','--http-chunk-size','1M','--throttled-rate','0')
    $result=Invoke-DownloaderProcess -Executable $bin.YtDlp -Arguments $nativeArgs -Directory $Root -OnLine $onNativeLine
    $detailLines=if($nativeErrors.Count){$nativeErrors.ToArray()}else{$nativeLines.ToArray()}
    return [pscustomobject]@{ExitCode=$result.ExitCode;Path=$nativePath;Details=(@($detailLines | Select-Object -Last 6) -join ' | ')}
}
function Download-CurlTrack($CurrentSession,$Format,[string]$TrackUrl,[string]$Target,[string]$Kind){
    $curl=Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if(-not $curl){return [pscustomobject]@{Available=$false;ExitCode=-1;Details='Không có curl trên Windows.'}}
    if(Test-Path -LiteralPath "$Target.native"){
        return [pscustomobject]@{Available=$true;ExitCode=0;Path="$Target.native";Details=''}
    }
    $path="$Target.curl.part"
    # yt-dlp native checkpoints are sequential too. Copy, never alter the original.
    if(-not (Test-Path -LiteralPath $path) -and (Test-Path -LiteralPath "$Target.native.part")){
        Copy-Item -LiteralPath "$Target.native.part" -Destination $path
    }
    $curlHeaders=@{Referer='https://www.bilibili.com/'}
    foreach($source in @($CurrentSession.Info.http_headers,$Format.http_headers)){
        if($source.Referer){$curlHeaders.Referer=[string]$source.Referer}
        if($source.'User-Agent'){$curlHeaders['User-Agent']=[string]$source.'User-Agent'}
    }
    $size=if($Format.filesize){[long]$Format.filesize}elseif($Format.filesize_approx){[long]$Format.filesize_approx}else{0L}
    $progress=@{bytes=if(Test-Path -LiteralPath $path){(Get-Item -LiteralPath $path).Length}else{0L};seconds=0.0}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $onProgress={param($bytes)
        $elapsed=$clock.Elapsed.TotalSeconds
        if($elapsed-$progress.seconds -lt 1){return}
        $speed=[Math]::Max(0,($bytes-$progress.bytes)/($elapsed-$progress.seconds)/1MB)
        $progress.bytes=$bytes;$progress.seconds=$elapsed
        $percent=if($size -gt 0){[Math]::Min(99,[int](100.0*$bytes/$size))}else{0}
        $script:overallPercent=if($Kind -eq 'video'){[int]($percent*0.9)}else{90+[int]($percent*0.09)}
        Set-DownloaderState 'downloading' ("curl {0}: {1}% | {2:N2} MiB/s | {3:N1} MiB" -f $Kind,$percent,$speed,($bytes/1MB)) $script:overallPercent
    }
    Set-DownloaderState 'downloading' ("Đang tải {0} bằng curl từ {1}; tiếp tục checkpoint riêng..." -f $Kind,([uri]$TrackUrl).Host) $script:overallPercent
    $expectedSize=if($Format.filesize){[long]$Format.filesize}else{0L}
    do{
        $result=Invoke-CurlDownload -Executable $curl.Source -Url $TrackUrl -Path $path -Headers $curlHeaders -Directory $scratch -ExpectedSize $expectedSize -OnProgress $onProgress
        if($result.TotalBytes -gt 0){$size=$result.TotalBytes}
    }while($result.ExitCode -eq 0 -and -not $result.Complete)
    return [pscustomobject]@{Available=$true;ExitCode=$result.ExitCode;Path=$result.Path;Details=$result.Details}
}
function Download-Track([string]$Kind,[string]$FormatId,[string]$Target,[int]$Height){
    $trackRecord=$manifest[$Kind]
    if(Test-Path -LiteralPath $Target){
        if(-not $trackRecord -or -not $trackRecord.complete -or (Get-Item -LiteralPath $Target).Length -ne $trackRecord.length){throw "Tệp đã có nhưng chưa được xác minh: $Target. Đổi tên tải để giữ tệp cũ."}
        $media=Test-DownloadedTrack $Target $Kind $Height $expectedDuration
        Set-DownloaderState 'downloading' ("Đã xác minh {0} có sẵn; tiếp tục tệp còn lại." -f $Kind) $script:overallPercent
        return $media
    }
    $partial="$Target.part"
    $inputPath=Join-Path $scratch ($Kind+'.aria2.txt')
    $modes=@(4,2,1)
    $singleConnection=$false
    $lastFailure=''
    $failureHistory=New-Object 'Collections.Generic.List[string]'
    for($attempt=0;$attempt -lt $modes.Count;$attempt++){
        if($attempt -gt 0 -or $Kind -eq 'audio'){
            $fresh=Get-BilibiliSession
            if($fresh.Info.id -ne $session.Info.id){throw 'Video đã thay đổi định danh; dừng để tránh ghép phần tải của hai video khác nhau.'}
            $currentSession=$fresh
        }else{$currentSession=$session}
        $format=$currentSession.Info.formats | Where-Object {$_.format_id -eq $FormatId} | Select-Object -First 1
        if(-not $format){throw 'Chất lượng đã chọn không còn khả dụng. Bấm Lấy chất lượng để làm mới; không tự hạ chất lượng.'}
        $urls=@(Get-TrackUrls $currentSession $format)
        if($urls.Count -eq 0){throw 'Bilibili không trả URL cho luồng đã chọn; phần dở được giữ.'}
        $headers=@()
        $referer=$null;$userAgent=$null
        foreach($source in @($currentSession.Info.http_headers,$format.http_headers)){
            if($source.Referer){$referer=$source.Referer};if($source.'User-Agent'){$userAgent=$source.'User-Agent'}
        }
        if(-not $referer){$referer='https://www.bilibili.com/'}
        $headers+="--header=Referer: $referer"
        if($userAgent){$headers+="--header=User-Agent: $userAgent"}
        $phase=if($Kind -eq 'video'){'video'}else{'âm thanh'}
        # Try every supplied signed URL explicitly. A failed mirror must not be picked
        # again by aria2 before the remaining mirrors have had a chance to resume.
        foreach($trackUrl in $urls){
            Write-AriaInput $inputPath @($trackUrl) ([IO.Path]::GetFileName($partial))
            $connections=if($singleConnection){1}else{$modes[$attempt]}
            $cdnHost=([uri]$trackUrl).Host
            Set-DownloaderState 'downloading' ("Đang tải {0} từ {1} ({2} kết nối, lượt {3}/3); tiếp tục phần dở..." -f $phase,$cdnHost,$connections,($attempt+1)) $script:overallPercent
            $recent=New-Object 'Collections.Generic.List[string]'
            $errorLines=New-Object 'Collections.Generic.List[string]'
            $onLine={param($line)
                $safe=Protect-DownloadLog $line
                if($recent.Count -ge 10){$recent.RemoveAt(0)};[void]$recent.Add($safe)
                if($line -match '\[ERROR\]|Exception:|errorCode=|HTTP.*status|Failed to|Permission denied|Access is denied'){
                    if($errorLines.Count -ge 10){$errorLines.RemoveAt(0)};[void]$errorLines.Add($safe)
                }
                if($line -match '\((\s*\d{1,3})%\)'){
                    $percent=[Math]::Min(100,[int]$Matches[1])
                    $script:overallPercent=if($Kind -eq 'video'){[int]($percent*0.9)}else{90+[int]($percent*0.09)}
                    $speed=if($line -match 'DL:([^\]\s]+)'){' | '+$Matches[1]+'/s'}else{''}
                    $eta=if($line -match 'ETA:([^\]\s]+)'){' | còn '+$Matches[1]}else{''}
                    Set-DownloaderState 'downloading' ("Đang tải {0}: {1}%{2}{3}" -f $phase,$percent,$speed,$eta) $script:overallPercent
                }
            }
            $lowestSpeed=if($Kind -eq 'video'){'256K'}else{'0'}
            $arguments=@('--no-conf=true',"--input-file=$inputPath","--dir=$dest",'--continue=true','--always-resume=true','--allow-overwrite=false','--auto-file-renaming=false','--auto-save-interval=2','--max-concurrent-downloads=1','--max-tries=2','--retry-wait=2','--timeout=30','--connect-timeout=20',"--split=$connections","--max-connection-per-server=$connections",'--min-split-size=1M',"--lowest-speed-limit=$lowestSpeed",'--file-allocation=none','--summary-interval=1','--console-log-level=notice','--show-console-readout=true')+$headers
            $nativeInProgress=(Test-Path -LiteralPath "$Target.native.part") -or (Test-Path -LiteralPath "$Target.native")
            $curlInProgress=Test-Path -LiteralPath "$Target.curl.part"
            $transportLabel='aria2'
            if($nativeInProgress -or $curlInProgress){$download=[pscustomobject]@{ExitCode=1}}
            else{$download=Invoke-DownloaderProcess -Executable $bin.Aria2 -Arguments $arguments -Directory $Root -OnLine $onLine}
            if($download.ExitCode -eq 0){
                if(Test-Path -LiteralPath "$partial.aria2"){throw 'aria2 còn ghi nhận phần chưa tải; giữ tệp dở để tiếp tục.'}
                return (Complete-Track $partial $Target $Kind $Height $format)
            }
            $details=if($errorLines.Count){@($errorLines.ToArray() | Select-Object -Last 6) -join ' | '}else{@($recent.ToArray() | Select-Object -Last 8) -join ' | '}
            if($download.ExitCode -in @(9,13,16,18) -or $details -match 'No space|not enough space|Permission denied|Access is denied|Failed to create'){
                throw "Không ghi được tệp (aria2 $($download.ExitCode)). Kiểm tra dung lượng, quyền thư mục và ứng dụng đang mở tệp. Chi tiết: $details"
            }
            $lastFailure="aria2 $($download.ExitCode): $details"
            [void]$failureHistory.Add("${cdnHost}: $details")
            $statuses=@(Get-DownloadHttpStatuses $details)
            if(567 -in $statuses -or 429 -in $statuses -or $details -match 'SocketCore\.cc|handle specified is invalid|SSL/TLS'){$singleConnection=$true}
            $curlResult=Download-CurlTrack $currentSession $format $trackUrl $Target $Kind
            if($curlResult.ExitCode -eq 0){
                $media=Complete-Track $curlResult.Path $Target $Kind $Height $format
                Write-Host "[curl] Đã xác minh $Kind hoàn tất."
                return $media
            }
            if($curlResult.Available){
                if($curlResult.ExitCode -in @(23,26)){throw "Không đọc/ghi được tệp curl; giữ phần dở. $($curlResult.Details)"}
                $transportLabel='curl'
                $details=(@($details,$curlResult.Details) | Where-Object {$_}) -join ' | '
                $lastFailure=$details
                [void]$failureHistory.Add("${cdnHost}: $($curlResult.Details)")
            }
            if(-not $curlResult.Available -or $attempt -eq $modes.Count-1){
                $native=Download-NativeTrack $currentSession $format $trackUrl $Target $Kind
                if($native.ExitCode -eq 0){return (Complete-Track $native.Path $Target $Kind $Height $format)}
                $transportLabel="HTTP yt-dlp $($native.ExitCode)"
                $details=(@($details,"${transportLabel}: $($native.Details)") | Where-Object {-not [string]::IsNullOrWhiteSpace($_)}) -join ' | '
                $lastFailure=$details
                [void]$failureHistory.Add("${cdnHost}: $($native.Details)")
            }
            Set-DownloaderState 'retrying' ("CDN {0} tải lỗi ({1}). {2} Đang chuyển URL dự phòng nếu có..." -f $cdnHost,$transportLabel,(Get-DownloadErrorHint $details)) $script:overallPercent
        }
        if($attempt -lt $modes.Count-1){
            $waitSeconds=if($singleConnection){5*($attempt+1)}else{2*($attempt+1)}
            $nextConnections=if($singleConnection){1}else{$modes[$attempt+1]}
            Set-DownloaderState 'retrying' ("Các CDN vừa thử đều lỗi; đợi {0} giây, lấy URL mới rồi tiếp tục với {1} kết nối..." -f $waitSeconds,$nextConnections) $script:overallPercent
            Start-Sleep -Seconds $waitSeconds
        }else{
            $history=@($failureHistory.ToArray() | Select-Object -Last 8) -join ' | '
            $hint=Get-DownloadErrorHint $history
            throw "Không tải được $phase sau 3 lượt làm mới, đã thử từng URL CDN. $hint Chi tiết cuối: $lastFailure. Phần dở được giữ; bấm tải lại với cùng link, chất lượng, tên và thư mục để tiếp tục."
        }
    }
}
try{
    $script:overallPercent=0
    if($OpenVocal){
        . (Join-Path $Root 'AppUpdate.Core.ps1')
        if(-not (Test-VocalPackage $Root)){
            $applicationLock=Open-ApplicationLock $Root -Exclusive
            Set-DownloaderState 'working' 'Đang hoàn tất module Vocal Remover từ gói cập nhật...'
            $null=Invoke-AppUpdate -Root $Root -RepairVocal
            $applicationLock.Dispose();$applicationLock=$null
            if(-not (Test-VocalPackage $Root)){throw 'Thiếu module Vocal Remover. Bấm Cập nhật ứng dụng rồi thử lại.'}
        }
        $applicationLock=Open-ApplicationLock $Root
        Set-DownloaderState 'working' 'Đang chuẩn bị Vocal Remover...'
        $python=Get-VocalPython $Root
        $dataRoot=Get-VocalDataRoot $Root
        $env:VOCAL_DATA_ROOT=$dataRoot
        $env:VOCAL_SETTINGS_PATH=Join-Path $dataRoot 'work/vocal-remover/ui-settings.json'
        $env:PYTHONUTF8='1'
        $env:PYTHONIOENCODING='utf-8'
        $entry=Join-Path $Root 'tools/vocal-remover/gui_entry.py'
        $vocalArgs=@($entry)
        if($VocalInput -and [IO.File]::Exists($VocalInput)){$vocalArgs+=@('--input',[IO.Path]::GetFullPath($VocalInput))}
        $startInfo=New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName=Join-Path ([IO.Path]::GetDirectoryName($python)) 'pythonw.exe'
        $startInfo.Arguments=(($vocalArgs | ForEach-Object {Quote-ProcessArgument ([string]$_)}) -join ' ')
        $startInfo.WorkingDirectory=$Root;$startInfo.UseShellExecute=$false;$startInfo.CreateNoWindow=$true
        $vocalProcess=[Diagnostics.Process]::Start($startInfo)
        Set-DownloaderState 'working' 'Vocal Remover đã mở. Đóng cửa sổ tách lời trước khi cập nhật ứng dụng.'
        $vocalProcess.WaitForExit()
        if($vocalProcess.ExitCode -ne 0){throw 'Vocal Remover không khởi động được; kiểm tra tools/vocal-remover/startup-error.log.'}
        Set-DownloaderState 'complete' 'Đã đóng Vocal Remover.' 100
        exit 0
    }
    if($UpdateApp){
        . (Join-Path $Root 'AppUpdate.Core.ps1')
        $applicationLock=Open-ApplicationLock $Root -Exclusive
        Set-DownloaderState 'working' 'Đang kiểm tra phiên bản ứng dụng trên GitHub...'
        $update=Invoke-AppUpdate -Root $Root -RepairVocal
        if($update.Updated){Set-DownloaderState 'complete' ("Đã cập nhật Bilibili và Vocal Remover lên {0}." -f $update.Version) 100}
        else{Set-DownloaderState 'complete' ("Ứng dụng đã ở phiên bản mới nhất: {0}." -f $update.Version) 100}
        exit 0
    }
    . (Join-Path $Root 'AppUpdate.Core.ps1')
    $applicationLock=Open-ApplicationLock $Root
    if(-not $SetupOnly -and -not $UpdateTools){
        if([string]::IsNullOrWhiteSpace($Url)){$Url=Read-Host 'Dán link trang video Bilibili'}
        $Url=ConvertTo-BilibiliUrl $Url
    }
    $bin=Get-Tooling
    if($SetupOnly -or $UpdateTools){Set-DownloaderState 'complete' 'Công cụ portable sẵn sàng.' 100;exit 0}
    $scratch=Join-Path $Work ([Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($scratch)
    $session=Get-BilibiliSession
    $info=$session.Info
    $qualities=@(Get-QualityChoices $info)
    $audio=$info.formats | Where-Object {$_.acodec -match '^mp4a' -and $_.ext -eq 'm4a' -and $_.vcodec -eq 'none' -and $_.url} | Sort-Object tbr -Descending | Select-Object -First 1
    if($qualities.Count -eq 0 -or -not $audio){throw 'Video không có luồng MP4 không tiếng và AAC riêng trong quyền truy cập hiện tại. Không thể tạo hai tệp đúng yêu cầu.'}
    $choices=@($qualities | ForEach-Object {@{format_id=$_.Format.format_id;height=$_.Height;fps=$_.Format.fps;codec=$_.Codec;size=$_.Format.filesize_approx;label=$_.Label;url=$Url}})
    if($ListQualities){Set-DownloaderState 'ready' ("Đã lấy chất lượng: {0}" -f $info.title) 0 $choices;exit 0}
    for($i=0;$i -lt $qualities.Count;$i++){Write-Host ("[{0}] {1}" -f ($i+1),$qualities[$i].Label)}
    if($InspectOnly){Write-Host ("{0} | {1} giây | AAC riêng" -f $info.title,$info.duration);exit 0}
    if($VideoFormatId){$selected=$qualities | Where-Object {$_.Format.format_id -eq $VideoFormatId} | Select-Object -First 1}
    else{
        do{$choice=0;$answer=Read-Host ("Chọn chất lượng 1-{0}" -f $qualities.Count)}while(-not [int]::TryParse($answer,[ref]$choice) -or $choice -lt 1 -or $choice -gt $qualities.Count)
        $selected=$qualities[$choice-1]
    }
    if(-not $selected){throw 'Chất lượng không còn khả dụng. Bấm Lấy chất lượng lại.'}
    $id=([uri]$Url).AbsolutePath.Trim('/').Split('/')[-1]
    $part=([regex]::Match($Url,'\?p=(\d+)')).Groups[1].Value
    if(-not $FileName){$FileName=$id+'_p'+$part}
    $FileName=ConvertTo-SafeFileName $FileName
    if(-not $OutputDirectory){$OutputDirectory=Join-Path ([Environment]::GetFolderPath('MyVideos')) $id}
    $dest=[IO.Path]::GetFullPath($OutputDirectory);[void][IO.Directory]::CreateDirectory($dest)
    if((Join-Path $dest ($FileName+'_video.mp4.part.aria2')).Length -gt 245){throw 'Đường dẫn lưu quá dài cho Windows. Chọn thư mục hoặc tên tệp ngắn hơn.'}
    $writeProbe=Join-Path $dest ('.write-'+[Guid]::NewGuid().ToString('N'));[IO.File]::WriteAllText($writeProbe,'');[IO.File]::Delete($writeProbe)
    $lockPath=Join-Path $dest ($FileName+'.download.lock')
    try{$destinationLock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'Tên tệp này đang được một tác vụ khác tải. Đợi tác vụ đó hoặc chọn tên khác.'}
    $manifestPath=Join-Path $dest ($FileName+'.bilibili.json')
    $identity=$Url+'|'+$info.id+'|'+$selected.Format.format_id+'|'+$audio.format_id
    $manifest=@{schema=1;identity=$identity;url=$Url;title=$info.title;video=$null;audio=$null}
    if(Test-Path -LiteralPath $manifestPath){
        $saved=Read-SharedJson $manifestPath
        if($saved.identity -ne $identity){throw 'Tên này đã dùng cho video, phần hoặc chất lượng khác. Nhập tên mới để không trộn/ghi đè tệp cũ.'}
        $manifest.video=$saved.video;$manifest.audio=$saved.audio
    }else{
        foreach($suffix in @('_video.mp4','_video.mp4.part','_video.mp4.native','_video.mp4.native.part','_audio.m4a','_audio.m4a.part','_audio.m4a.native','_audio.m4a.native.part')){
            if(Test-Path -LiteralPath (Join-Path $dest ($FileName+$suffix))){throw 'Tên tệp đã tồn tại nhưng chưa có hồ sơ tải xác minh. Chọn tên khác để bảo toàn tệp cũ.'}
        }
        Save-Manifest
    }
    $expectedDuration=[double]$info.duration
    $videoMedia=Download-Track 'video' $selected.Format.format_id (Join-Path $dest ($FileName+'_video.mp4')) $selected.Height
    $script:overallPercent=90
    $audioMedia=Download-Track 'audio' $audio.format_id (Join-Path $dest ($FileName+'_audio.m4a')) 0
    if([Math]::Abs($videoMedia.Duration-$audioMedia.Duration) -gt 5){throw 'Thời lượng video và âm thanh lệch quá 5 giây. Hai tệp được giữ để kiểm tra.'}
    Set-DownloaderState 'packaging' 'Đã tải đủ video và âm thanh. Đang tạo và kiểm tra ZIP cho CapCut...' 99
    $package=New-CapCutInputZip (Join-Path $dest ($FileName+'stage1.zip')) (Join-Path $dest ($FileName+'_video.mp4')) (Join-Path $dest ($FileName+'_audio.m4a'))
    Set-DownloaderState 'complete' ("Hoàn tất. ZIP dùng cho CapCut giai đoạn 1: {0}" -f $package.Path) 100
    exit 0
}catch{
    $message=Protect-DownloadLog $_.Exception.Message
    Set-DownloaderState 'error' ("Lỗi: {0}" -f $message) $script:overallPercent
    exit 1
}finally{
    if($applicationLock){$applicationLock.Dispose()}
    if($destinationLock){$destinationLock.Dispose()}
    if($scratch -and (Test-Path -LiteralPath $scratch)){
        # Scratch only contains this worker's extraction dumps and signed CDN URLs.
        $resolved=[IO.Path]::GetFullPath($scratch)
        if($resolved.StartsWith([IO.Path]::GetFullPath($Work)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
