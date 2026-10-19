# Shared by the GUI, worker and regression checks. Compatible with Windows PowerShell 5.1.
function Open-DownloadOutputLock([string]$Path) {
    # Windows removes the lock even when the GUI terminates the worker process.
    return [IO.FileStream]::new($Path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,4096,[IO.FileOptions]::DeleteOnClose)
}

function Get-DownloadRecordPath([string]$WorkDirectory,[string]$Directory,[string]$FileName) {
    # Keep the identity needed to reuse completed media outside the output folder.
    $identity=(Join-Path ([IO.Path]::GetFullPath($Directory)) $FileName).ToUpperInvariant()
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity)))).Replace('-','')}
    finally{$sha.Dispose()}
    return Join-Path (Join-Path $WorkDirectory 'download-records') ($key+'.json')
}

function Remove-CompletedDownloadParts([string]$Directory,[string]$FileName) {
    if((ConvertTo-SafeFileName $FileName) -cne $FileName){throw 'Tên dọn tệp tạm không hợp lệ.'}
    $folder=[IO.Path]::GetFullPath($Directory)
    # Exact job filenames only; never glob media, other jobs or subdirectories.
    foreach($track in @('_video.mp4','_audio.m4a')){
        foreach($suffix in @('.part','.part.aria2','.native','.native.part','.native.ytdl','.curl.part')){
            $path=Join-Path $folder ($FileName+$track+$suffix)
            if([IO.File]::Exists($path)){
                try{Remove-Item -LiteralPath $path -Force -ErrorAction Stop}
                catch{Write-Warning ("Đã tải xong nhưng chưa dọn được tệp tạm: {0}" -f [IO.Path]::GetFileName($path))}
            }
        }
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory=$true)][string]$LiteralPath)
    $path=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LiteralPath)
    $sha=[Security.Cryptography.SHA256]::Create()
    $stream=$null
    try{
        $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','')
    }finally{
        if($stream){$stream.Dispose()}
        $sha.Dispose()
    }
}

function Test-CapCutInputZip([string]$Path, $Files) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if($archive.Entries.Count -ne $Files.Count){throw 'ZIP đã có không chứa đúng hai tệp đầu vào; giữ nguyên ZIP cũ.'}
        foreach($file in $Files){
            $entry=$archive.GetEntry($file.Name)
            if(-not $entry -or $entry.Length -ne $file.Length){throw 'Nội dung ZIP không khớp video/âm thanh; giữ nguyên ZIP cũ.'}
            $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
            try{$hash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','')}
            finally{$stream.Dispose();$sha.Dispose()}
            if($hash -ne $file.Hash){throw 'SHA-256 trong ZIP không khớp tệp nguồn; giữ nguyên ZIP cũ.'}
        }
    }finally{$archive.Dispose()}
}

function New-CapCutInputZip([string]$Path,[string]$VideoPath,[string]$AudioPath) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $files=@(foreach($source in @($VideoPath,$AudioPath)){
        $file=Get-Item -LiteralPath $source -ErrorAction Stop
        if($file.PSIsContainer -or $file.Length -le 0){throw 'Chỉ đóng gói sau khi có đủ hai tệp media hoàn tất.'}
        [pscustomobject]@{Path=$file.FullName;Name=$file.Name;Length=$file.Length;Hash=(Get-FileSha256 -LiteralPath $file.FullName)}
    })
    $fullPath=[IO.Path]::GetFullPath($Path)
    if(Test-Path -LiteralPath $fullPath){
        Test-CapCutInputZip $fullPath $files
        return [pscustomobject]@{Path=$fullPath;Reused=$true;Files=$files}
    }
    $temp="$fullPath.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    try{
        # Stream media without recompression; ZipArchive emits ZIP64 for large files.
        $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{
            $archive=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
            try{
                foreach($file in $files){
                    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$file.Path,$file.Name,[IO.Compression.CompressionLevel]::NoCompression)
                }
            }finally{$archive.Dispose()}
        }finally{$stream.Dispose()}
        Test-CapCutInputZip $temp $files
        [IO.File]::Move($temp,$fullPath)
        return [pscustomobject]@{Path=$fullPath;Reused=$false;Files=$files}
    }finally{
        if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}
    }
}

function Write-AtomicJson([string]$Path, $Value) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath))
    $temp = "$fullPath.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    $backup = "$temp.bak"
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            try {
                if ([IO.File]::Exists($fullPath)) { [IO.File]::Replace($temp, $fullPath, $backup) }
                else { [IO.File]::Move($temp, $fullPath) }
                return
            } catch [IO.IOException] {
                if ($attempt -eq 19) { throw }
                Start-Sleep -Milliseconds 25
            }
        }
    } finally {
        foreach ($pathToClean in @($temp, $backup)) {
            try { if ([IO.File]::Exists($pathToClean)) { [IO.File]::Delete($pathToClean) } } catch { }
        }
    }
}

function Read-SharedJson([string]$Path) {
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
            try {
                $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
                try { $json = $reader.ReadToEnd() } finally { $reader.Dispose() }
            } finally { $stream.Dispose() }
            return ($json | ConvertFrom-Json)
        } catch [IO.IOException] {
            if ($attempt -eq 2) { throw }
            Start-Sleep -Milliseconds 10
        }
    }
}

function ConvertTo-BilibiliUrl([string]$Value) {
    $parsed = $null
    if (-not [uri]::TryCreate($Value.Trim(), [UriKind]::Absolute, [ref]$parsed) -or
        $parsed.Scheme -notin @('https', 'http') -or $parsed.Host -notin @('bilibili.com', 'www.bilibili.com') -or
        $parsed.AbsolutePath -notmatch '^/video/(?<id>BV[0-9A-Za-z]+|av\d+)/?$') {
        throw 'Dán link trang video https://www.bilibili.com/video/BV.../ hoặc av...; không dùng link token BraveDown.'
    }
    $id = $Matches['id']
    $part = 1
    $partMatches = [regex]::Matches($parsed.Query, '(?:^\?|&)p=([^&]*)')
    if ($partMatches.Count -gt 1) { throw 'Link có nhiều tham số p. Hãy giữ đúng một phần video.' }
    if ($partMatches.Count -eq 1 -and (-not [int]::TryParse($partMatches[0].Groups[1].Value, [ref]$part) -or $part -lt 1)) {
        throw 'Số phần p trong link phải là số nguyên từ 1 trở lên.'
    }
    return "https://www.bilibili.com/video/$id/?p=$part"
}

function ConvertTo-SafeFileName([string]$Value) {
    $safe = [regex]::Replace($Value, '[\x00-\x1f\\/:*?"<>|]', '_').Trim().TrimEnd([char[]]@(' ', '.'))
    if ([string]::IsNullOrWhiteSpace($safe)) { throw 'Tên tệp trống hoặc không hợp lệ. Nhập tên khác.' }
    if ($safe -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { $safe = '_' + $safe }
    if ($safe.Length -gt 120) { $safe = $safe.Substring(0, 120).TrimEnd([char[]]@(' ', '.')) }
    return $safe
}

function Quote-ProcessArgument([string]$Value) {
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Protect-DownloadLog([string]$Text) {
    # Redaction is used at several boundaries; a second pass must not grow the marker.
    return [regex]::Replace($Text, '(https?://[^\s?]+)\?(?:\[signed query hidden\]|[^\s]*)', '$1?[signed query hidden]')
}

function Get-DownloadHttpStatuses([string]$Text) {
    # Never interpret digits in a URL, source filename, line number or errorCode as HTTP.
    return @([regex]::Matches($Text, '(?i)(?:\bstatus\s*[=:]\s*|\bHTTP(?:/\d(?:\.\d)?)?\s+(?:Error\s+)?)([1-5]\d{2})\b') |
        ForEach-Object { [int]$_.Groups[1].Value } | Select-Object -Unique)
}

function Get-DownloadErrorHint([string]$Text) {
    if($Text -match 'ThrottledDownload|below throttle limit') { return 'Bộ tải đã dừng vì ngưỡng tốc độ thấp. Tệp dở vẫn được giữ; bản mới cho phép tiếp tục dù tải chậm, không cần đổi quyền truy cập video.' }
    $statuses = @(Get-DownloadHttpStatuses $Text)
    if (567 -in $statuses) { return 'CDN Bilibili trả HTTP 567 và từ chối yêu cầu tải hiện tại. Chưa đủ bằng chứng để kết luận video bị xóa; thử CDN khác và URL mới, phần dở được giữ.' }
    if (429 -in $statuses) { return 'Máy chủ giới hạn số yêu cầu (HTTP 429). Đợi một lúc rồi tải lại; phần dở được giữ.' }
    if (403 -in $statuses -or 401 -in $statuses) { return 'Máy chủ từ chối yêu cầu. URL đã được làm mới khi thử lại; nếu vẫn lỗi, kiểm tra quyền truy cập video hoặc cập nhật công cụ.' }
    if (@($statuses | Where-Object { $_ -ge 500 }).Count) { return 'Máy chủ CDN trả lỗi HTTP 5xx. Phần dở được giữ để thử CDN khác hoặc tải tiếp sau.' }
    if (404 -in $statuses -or $Text -match '\bNot Found\b') { return 'Máy chủ không tìm thấy tài nguyên (HTTP 404). Kiểm tra video gốc còn xem được và phần p có tồn tại.' }
    if ($Text -match 'SocketCore\.cc|handle specified is invalid|80090301|SSL/TLS|TLS handshake') { return 'Kết nối socket/TLS của công cụ tải bị lỗi. Đây chưa phải bằng chứng ổ lưu hoặc tệp bị hỏng; phần dở được giữ để thử lại.' }
    switch -Regex ($Text) {
        'resolve|DNS|getaddrinfo' { return 'Không phân giải được tên máy chủ (DNS). Kiểm tra đường kết nối tới Bilibili rồi thử lại.' }
        'No space|not enough space|disk full' { return 'Ổ lưu không đủ dung lượng. Giải phóng dung lượng hoặc chọn thư mục khác.' }
        'being used by another process|sharing violation' { return 'Tệp đang được ứng dụng khác sử dụng. Đóng ứng dụng đang mở tệp rồi tải tiếp.' }
        'Permission denied|Access is denied' { return 'Không có quyền ghi thư mục. Chọn thư mục có quyền ghi.' }
        'timeout|timed out|connection|network|reset' { return 'Kết nối tới máy chủ tải bị gián đoạn. Phần dở được giữ để thử lại.' }
        default { return 'Xem chi tiết lỗi; nếu lỗi trích xuất định dạng, bấm Cập nhật công cụ. Video giới hạn quyền cần được truy cập hợp lệ.' }
    }
}

function Invoke-DownloaderProcess {
    param([string]$Executable, [string[]]$Arguments, [string]$Directory, [scriptblock]$OnLine, [int]$TimeoutSeconds = 0)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $psi.Arguments = (($Arguments | ForEach-Object { Quote-ProcessArgument $_ }) -join ' ')
    $psi.WorkingDirectory = $Directory
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    $stdout = New-Object 'Collections.Generic.List[string]'
    $stderr = New-Object 'Collections.Generic.List[string]'
    try {
        [void]$process.Start()
        $started = [DateTime]::UtcNow
        $outTask = $process.StandardOutput.ReadLineAsync()
        $errTask = $process.StandardError.ReadLineAsync()
        while ($null -ne $outTask -or $null -ne $errTask -or -not $process.HasExited) {
            if ($TimeoutSeconds -gt 0 -and ([DateTime]::UtcNow - $started).TotalSeconds -gt $TimeoutSeconds) {
                throw "Tác vụ vượt quá $TimeoutSeconds giây. Kiểm tra kết nối tới máy chủ rồi thử lại."
            }
            if ($null -ne $outTask -and $outTask.IsCompleted) {
                $line = $outTask.GetAwaiter().GetResult()
                if ($null -eq $line) { $outTask = $null } else {
                    if ($stdout.Count -ge 200) { $stdout.RemoveAt(0) }; [void]$stdout.Add($line)
                    if ($OnLine) { & $OnLine $line }
                    $outTask = $process.StandardOutput.ReadLineAsync()
                }
            }
            if ($null -ne $errTask -and $errTask.IsCompleted) {
                $line = $errTask.GetAwaiter().GetResult()
                if ($null -eq $line) { $errTask = $null } else {
                    if ($stderr.Count -ge 200) { $stderr.RemoveAt(0) }; [void]$stderr.Add($line)
                    if ($OnLine) { & $OnLine $line }
                    $errTask = $process.StandardError.ReadLineAsync()
                }
            }
            if ($null -ne $outTask -or $null -ne $errTask -or -not $process.HasExited) { Start-Sleep -Milliseconds 10 }
        }
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = @($stdout.ToArray()); StdErr = @($stderr.ToArray()) }
    } finally {
        try { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() } } catch { }
        $process.Dispose()
    }
}

function Write-AriaInput([string]$Path, [string[]]$Urls, [string]$TargetName) {
    $urlsToUse = @($Urls | Where-Object { $_ -and $_ -notmatch '[\r\n\t]' } | Select-Object -Unique)
    if ($urlsToUse.Count -eq 0 -or $TargetName -match '[\r\n]') { throw 'Danh sách URL tải hoặc tên tệp không hợp lệ.' }
    # aria2 mirrors MUST share one TAB-separated line; per-item options are indented.
    $text = ($urlsToUse -join "`t") + "`n  out=$TargetName`n"
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($false)))
}

function Get-TrackUrls($Session, $Format) {
    $urls = New-Object 'Collections.Generic.List[string]'
    $primary = [uri]$Format.url
    [void]$urls.Add([string]$Format.url)
    foreach ($dash in @($Session.Dashes)) {
        foreach ($item in @($dash.video) + @($dash.audio)) {
            $base = if ($item.baseUrl) { $item.baseUrl } else { $item.base_url }
            if (-not $base) { continue }
            $matchesPath = ([uri]$base).AbsolutePath -eq $primary.AbsolutePath
            if (-not $matchesPath) { continue }
            $backups = if ($item.backupUrl) { @($item.backupUrl) } else { @($item.backup_url) }
            [void]$urls.Add([string]$base)
            foreach ($backup in $backups) { if ($backup) { [void]$urls.Add([string]$backup) } }
        }
    }
    [void]$urls.Add([string]$Format.url)
    return @($urls.ToArray() | Where-Object { $_ -match '^https?://' } | Select-Object -Unique)
}

function Invoke-CurlDownload {
    param([string]$Executable,[string]$Url,[string]$Path,[hashtable]$Headers,
        [string]$Directory,[long]$ExpectedSize=0,[scriptblock]$OnProgress,
        [int]$LowSpeedLimit=262144,[int]$LowSpeedSeconds=30,[long]$ChunkBytes=8MB)
    # This checkpoint is a contiguous prefix. Never pass an aria2 sparse file here.
    $offset=if([IO.File]::Exists($Path)){(Get-Item -LiteralPath $Path).Length}else{0L}
    $config=Join-Path $Directory ([Guid]::NewGuid().ToString('N')+'.curl.conf')
    $headerPath=$config+'.headers'
    $quote={param([string]$Value)
        if($Value -match '[\r\n\x00]'){throw 'Giá trị cấu hình curl không hợp lệ.'}
        return '"'+$Value.Replace('\','\\').Replace('"','\"')+'"'
    }
    $lines=@('url = '+(& $quote $Url))
    foreach($key in $Headers.Keys){$lines+='header = '+(& $quote ($key+': '+$Headers[$key]))}
    $lines+='header = "Accept-Encoding: identity"'
    # Bilibili CDNs may reject open-ended requests while accepting bounded ranges.
    $lines+='header = "Range: bytes='+$offset+'-'+($offset+$ChunkBytes-1)+'"'
    $errors=New-Object 'Collections.Generic.List[string]'
    $onLine={param($line)
        if($line -match '^curl:'){
            if($errors.Count -ge 4){$errors.RemoveAt(0)}
            [void]$errors.Add((Protect-DownloadLog $line))
        }
        if($OnProgress -and $line -match '^\s*\d{1,3}\s+\S+\s+\d{1,3}\s+'){
            if([IO.File]::Exists($Path)){& $OnProgress (Get-Item -LiteralPath $Path).Length}
        }
    }
    try{
        [IO.File]::WriteAllLines($config,$lines,(New-Object Text.UTF8Encoding($false)))
        $arguments=@('--disable','--config',$config,'--location','--max-redirs','5',
            '--proto','=http,https','--proto-redir','=http,https','--fail',
            '--continue-at','-','--output',$Path,'--dump-header',$headerPath,
            '--connect-timeout','20','--speed-limit',[string]$LowSpeedLimit,
            '--speed-time',[string]$LowSpeedSeconds,'--retry','0')
        $run=Invoke-DownloaderProcess -Executable $Executable -Arguments $arguments -Directory $Directory -OnLine $onLine
        $code=$run.ExitCode
        $raw=if([IO.File]::Exists($headerPath)){[IO.File]::ReadAllText($headerPath)}else{''}
        $blocks=[regex]::Matches($raw,'(?m)^HTTP/[^\r\n]+')
        $last=if($blocks.Count){$raw.Substring($blocks[$blocks.Count-1].Index)}else{''}
        $status=if($last -match '^HTTP/\S+\s+(\d{3})'){[int]$Matches[1]}else{0}
        $total=0L;$valid=$false
        if($status -eq 206 -and $last -match '(?im)^Content-Range:\s*bytes\s+(\d+)-(\d+)/(\d+)\s*\r?$'){
            $start=[long]$Matches[1];$end=[long]$Matches[2];$total=[long]$Matches[3]
            $valid=$start -eq $offset -and $end -ge $start -and $end -lt $total
        }elseif($status -eq 200 -and $offset -eq 0){
            $valid=$true
            if($last -match '(?im)^Content-Length:\s*(\d+)\s*\r?$'){$total=[long]$Matches[1]}
        }elseif($status -eq 416 -and $last -match '(?im)^Content-Range:\s*bytes\s+\*/(\d+)\s*\r?$'){
            $total=[long]$Matches[1]
            $valid=$offset -gt 0 -and $offset -eq $total
            if($valid){$code=0}
        }
        if($ExpectedSize -gt 0 -and $total -gt 0 -and $ExpectedSize -ne $total){$valid=$false}
        $length=if([IO.File]::Exists($Path)){(Get-Item -LiteralPath $Path).Length}else{0L}
        if($valid -and (($total -gt 0 -and $length -gt $total) -or ($status -eq 206 -and $length -gt $end+1))){$valid=$false}
        if(-not $valid){
            # A bad/ignored Range response must never poison the resumable prefix.
            if($length -gt $offset){
                $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try{$stream.SetLength($offset)}finally{$stream.Dispose()}
            }
            if($code -eq 0){$code=33}
        }
        $complete=$valid -and $code -eq 0
        if($complete -and $total -gt 0 -and $length -ne $total){
            $complete=$false
            if($status -ne 206 -or $length -ne $end+1){$code=18}
        }
        if($code -eq 0 -and $length -eq 0){$code=18;$complete=$false}
        $detail="curl $code, HTTP $status"
        if(-not $valid){$detail+=': phản hồi Range hoặc dung lượng không khớp; giữ nguyên phần dở.'}
        if($errors.Count){$detail+=' | '+($errors.ToArray() -join ' | ')}
        return [pscustomobject]@{ExitCode=$code;Path=$Path;Details=$detail;TotalBytes=$total;Complete=$complete}
    }finally{
        foreach($file in @($config,$headerPath)){if([IO.File]::Exists($file)){[IO.File]::Delete($file)}}
    }
}

function Initialize-MediaInspector {
    if ('BilibiliMediaInspector' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
public class BilibiliMediaInfo {
    public int VideoTracks, AudioTracks, Width, Height;
    public double Duration;
    public bool HasMedia;
}
public static class BilibiliMediaInspector {
    static uint U32(BinaryReader r) { byte[] b=r.ReadBytes(4); if(b.Length!=4)throw new InvalidDataException("Truncated MP4"); return ((uint)b[0]<<24)|((uint)b[1]<<16)|((uint)b[2]<<8)|b[3]; }
    static ulong U64(BinaryReader r) { return ((ulong)U32(r)<<32)|U32(r); }
    static string Four(BinaryReader r) { byte[] b=r.ReadBytes(4);if(b.Length!=4)throw new InvalidDataException("Truncated MP4");return Encoding.ASCII.GetString(b); }
    static void Boxes(BinaryReader r, long end, BilibiliMediaInfo info, int depth) {
        if(depth>8)throw new InvalidDataException("MP4 nesting limit");
        while(r.BaseStream.Position<end) {
            long start=r.BaseStream.Position;
            if(end-start<8)throw new InvalidDataException("Truncated MP4 box");
            ulong size=U32(r); string type=Four(r); long header=8;
            if(size==1){size=U64(r);header=16;} else if(size==0){size=(ulong)(end-start);}
            if(size<(ulong)header||size>(ulong)(end-start))throw new InvalidDataException("Incomplete MP4 box: "+type);
            long stop=start+(long)size; long data=start+header;
            if(type=="moov"||type=="trak"||type=="mdia") { Boxes(r,stop,info,depth+1); }
            else if(type=="mdat") { if(size>(ulong)header)info.HasMedia=true; }
            else if(type=="hdlr"&&stop-data>=12) { r.BaseStream.Position=data+8;string kind=Four(r);if(kind=="vide")info.VideoTracks++;if(kind=="soun")info.AudioTracks++; }
            else if(type=="tkhd"&&stop-data>=8) { r.BaseStream.Position=stop-8;int w=(int)(U32(r)>>16);int h=(int)(U32(r)>>16);if(w>info.Width)info.Width=w;if(h>info.Height)info.Height=h; }
            else if((type=="mvhd"||type=="mdhd")&&stop-data>=20) {
                int version=r.ReadByte();if(version>1||stop-data<(version==1?32:20))throw new InvalidDataException("Invalid MP4 duration header");r.BaseStream.Position=data+(version==1?20:12);
                uint scale=U32(r);ulong duration=version==1?U64(r):U32(r);
                if(scale>0&&duration!=UInt32.MaxValue&&duration!=UInt64.MaxValue){double d=(double)duration/scale;if(d>info.Duration)info.Duration=d;}
            } else if(type=="sidx"&&stop-data>=24) {
                int version=r.ReadByte();if(version>1||stop-data<(version==1?32:24))throw new InvalidDataException("Invalid sidx header");r.BaseStream.Position=data+8;uint scale=U32(r);
                r.BaseStream.Position=data+(version==1?28:20);r.ReadBytes(2);byte[] cb=r.ReadBytes(2);
                int count=(cb[0]<<8)|cb[1];ulong sum=0;
                if(r.BaseStream.Position+count*12>stop)throw new InvalidDataException("Incomplete sidx");
                for(int i=0;i<count;i++){U32(r);sum+=U32(r);U32(r);}
                if(scale>0){double d=(double)sum/scale;if(d>info.Duration)info.Duration=d;}
            }
            r.BaseStream.Position=stop;
        }
    }
    public static BilibiliMediaInfo Inspect(string path) {
        BilibiliMediaInfo info=new BilibiliMediaInfo();
        using(FileStream s=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read))
        using(BinaryReader r=new BinaryReader(s)){if(s.Length<32)throw new InvalidDataException("Media file too small");Boxes(r,s.Length,info,0);}
        if(!info.HasMedia||info.VideoTracks+info.AudioTracks==0)throw new InvalidDataException("MP4 missing media or tracks");
        return info;
    }
}
'@
}

function Test-DownloadedTrack([string]$Path, [string]$Kind, [int]$Height = 0, [double]$ExpectedDuration = 0) {
    Initialize-MediaInspector
    $media = [BilibiliMediaInspector]::Inspect($Path)
    if ($Kind -eq 'video' -and ($media.VideoTracks -ne 1 -or $media.AudioTracks -ne 0)) { throw 'Tệp video không đúng một luồng hình riêng, không âm thanh.' }
    if ($Kind -eq 'audio' -and ($media.AudioTracks -ne 1 -or $media.VideoTracks -ne 0)) { throw 'Tệp âm thanh không đúng một luồng tiếng riêng.' }
    if ($Height -gt 0 -and $media.Height -ne $Height) { throw "Độ cao video $($media.Height) không khớp mức đã chọn $Height." }
    if ($media.Duration -le 0) { throw 'Không xác nhận được thời lượng tệp tải.' }
    if ($ExpectedDuration -gt 0 -and [Math]::Abs($media.Duration - $ExpectedDuration) -gt [Math]::Max(5, $ExpectedDuration * 0.005)) { throw 'Thời lượng tệp tải không khớp video gốc; giữ phần tải để kiểm tra.' }
    return $media
}
