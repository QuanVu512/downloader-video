function Get-AppRuntimeFiles {
    return @('Downloader.Core.ps1','AppUpdate.Core.ps1','Start-Bilibili-Download.ps1','Start-GUI.ps1','Start.bat','Start-CLI.bat','README.txt','VERSION.txt')
}

function Open-ApplicationLock([string]$Root,[switch]$Exclusive) {
    $workPath=Join-Path $Root 'work'
    [void][IO.Directory]::CreateDirectory($workPath)
    $sharing=if($Exclusive){[IO.FileShare]::None}else{[IO.FileShare]::ReadWrite}
    try{return [IO.File]::Open((Join-Path $workPath 'application.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,$sharing)}
    catch [IO.IOException]{throw 'Ứng dụng khác đang tải hoặc cập nhật. Đợi tác vụ đó hoàn tất rồi thử lại.'}
}

function Get-AppUpdatePlan($Release,[string]$InstalledVersion) {
    if($Release.draft -or $Release.prerelease -or $Release.tag_name -notmatch '^v(\d+\.\d+\.\d+)$'){throw 'Phiên bản phát hành trên GitHub không hợp lệ.'}
    $version=$Matches[1]
    if([version]$version -le [version]$InstalledVersion){return [pscustomobject]@{Available=$false;Version=$InstalledVersion}}
    $name="Bilibili-Downloader-Windows-$version.zip"
    $base="https://github.com/QuanVu512/downloader-video/releases/download/v$version/"
    $zip=@($Release.assets | Where-Object {$_.name -ceq $name})
    $sum=@($Release.assets | Where-Object {$_.name -ceq ($name+'.sha256')})
    if($zip.Count -ne 1 -or $sum.Count -ne 1 -or $zip[0].browser_download_url -cne ($base+$name) -or $sum[0].browser_download_url -cne ($base+$name+'.sha256')){throw 'Bản phát hành thiếu ZIP/checksum hoặc địa chỉ không thuộc repo ứng dụng.'}
    return [pscustomobject]@{Available=$true;Version=$version;Name=$name;ZipUrl=$zip[0].browser_download_url;ChecksumUrl=$sum[0].browser_download_url}
}

function Copy-AppFileAtomic([string]$Source,[string]$Destination) {
    $temp=$Destination+'.update-'+[Guid]::NewGuid().ToString('N')+'.tmp'
    $swapBackup=$temp+'.old'
    try{
        [IO.File]::Copy($Source,$temp,$false)
        if([IO.File]::Exists($Destination)){[IO.File]::Replace($temp,$Destination,$swapBackup)}
        else{[IO.File]::Move($temp,$Destination)}
    }finally{foreach($ownFile in @($temp,$swapBackup)){if([IO.File]::Exists($ownFile)){[IO.File]::Delete($ownFile)}}}
}

function Install-AppPackage([string]$Root,[string]$PackagePath,[string]$ExpectedHash,[string]$ExpectedVersion) {
    if($ExpectedHash -notmatch '^[0-9a-fA-F]{64}$' -or (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash -ne $ExpectedHash){throw 'SHA-256 bản cập nhật không khớp; giữ nguyên ứng dụng hiện tại.'}
    if($ExpectedVersion -notmatch '^\d+\.\d+\.\d+$'){throw 'Phiên bản cập nhật không hợp lệ.'}
    $attempt=Join-Path (Join-Path $Root 'work') ('app-update-'+[Guid]::NewGuid().ToString('N'))
    $candidate=Join-Path $attempt 'candidate';$backup=Join-Path $attempt 'backup'
    [void][IO.Directory]::CreateDirectory($candidate);[void][IO.Directory]::CreateDirectory($backup)
    $runtime=@(Get-AppRuntimeFiles)
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($PackagePath)
    try{
        foreach($entry in $archive.Entries){
            $name=$entry.FullName.Replace('\','/')
            if($name -notmatch '^Bilibili-Downloader/' -or $name -match '(^|/)\.\.(/|$)|:|^/' -or -not $seen.Add($name)){throw 'ZIP cập nhật có đường dẫn không an toàn hoặc trùng lặp.'}
            $relative=$name.Substring('Bilibili-Downloader/'.Length)
            if(-not $relative -or $relative.EndsWith('/')){continue}
            if($relative.StartsWith('tools/')){continue} # Tool updates are separate; preserve installed executables.
            if($relative -cnotin $runtime -or $entry.Length -gt 2MB){throw "Tệp không hợp lệ trong bản cập nhật: $relative"}
            $inputStream=$entry.Open()
            $outputStream=[IO.File]::Open((Join-Path $candidate $relative),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
            try{$inputStream.CopyTo($outputStream)}finally{$inputStream.Dispose();$outputStream.Dispose()}
        }
    }finally{$archive.Dispose()}
    foreach($name in $runtime){if(-not [IO.File]::Exists((Join-Path $candidate $name))){throw "Bản cập nhật thiếu $name; giữ nguyên ứng dụng."}}
    $version=(Get-Content -LiteralPath (Join-Path $candidate 'VERSION.txt') -TotalCount 1).Trim()
    if($version -cne $ExpectedVersion){throw 'VERSION.txt trong ZIP không khớp phiên bản phát hành.'}
    foreach($file in Get-ChildItem -LiteralPath $candidate -Filter '*.ps1' -File){
        $tokens=$null;$errors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        if(@($errors).Count){throw "Script cập nhật không hợp lệ: $($file.Name)"}
    }
    foreach($name in $runtime){
        $old=Join-Path $Root $name
        if([IO.File]::Exists($old)){[IO.File]::Copy($old,(Join-Path $backup $name),$false)}
    }
    $applied=New-Object 'Collections.Generic.List[string]'
    try{
        # VERSION is last so an interrupted update never advertises completion early.
        foreach($name in $runtime){Copy-AppFileAtomic (Join-Path $candidate $name) (Join-Path $Root $name);[void]$applied.Add($name)}
    }catch{
        $cause=$_.Exception.Message;$rollbackErrors=New-Object 'Collections.Generic.List[string]'
        for($index=$applied.Count-1;$index -ge 0;$index--){
            $name=$applied[$index];$old=Join-Path $backup $name;$target=Join-Path $Root $name
            try{if([IO.File]::Exists($old)){Copy-AppFileAtomic $old $target}else{[IO.File]::Delete($target)}}catch{[void]$rollbackErrors.Add($name)}
        }
        if($rollbackErrors.Count){throw "Cập nhật lỗi; cần khôi phục các tệp $($rollbackErrors -join ', ') từ $backup. Nguyên nhân: $cause"}
        throw "Cập nhật lỗi, đã hoàn nguyên các tệp đã đổi. Bản sao: $backup. Nguyên nhân: $cause"
    }
    return [pscustomobject]@{Updated=$true;Version=$version;Backup=$backup}
}

function Invoke-AppUpdate([string]$Root) {
    $version=(Get-Content -LiteralPath (Join-Path $Root 'VERSION.txt') -TotalCount 1).Trim()
    try{$release=Invoke-RestMethod -Uri 'https://api.github.com/repos/QuanVu512/downloader-video/releases/latest' -Headers @{'User-Agent'='Bilibili-Downloader';Accept='application/vnd.github+json'} -TimeoutSec 30}
    catch{throw 'Không lấy được bản phát hành ứng dụng. Kiểm tra kết nối và trang GitHub Releases của QuanVu512/downloader-video.'}
    $plan=Get-AppUpdatePlan $release $version
    if(-not $plan.Available){return [pscustomobject]@{Updated=$false;Version=$version}}
    $folder=Join-Path (Join-Path $Root 'work') ('app-download-'+[Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($folder)
    $zipPath=Join-Path $folder $plan.Name;$sumPath=$zipPath+'.sha256'
    Invoke-WebRequest -UseBasicParsing -Uri $plan.ChecksumUrl -OutFile $sumPath -TimeoutSec 60
    $checksum=[IO.File]::ReadAllText($sumPath).Trim()
    if($checksum -notmatch ('^([a-fA-F0-9]{64})\s+\*?'+[regex]::Escape($plan.Name)+'$')){throw 'Checksum phát hành không hợp lệ.'}
    $expected=$Matches[1]
    Invoke-WebRequest -UseBasicParsing -Uri $plan.ZipUrl -OutFile $zipPath -TimeoutSec 180
    return (Install-AppPackage $Root $zipPath $expected $plan.Version)
}
