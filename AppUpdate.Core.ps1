function Get-AppRuntimeFiles {
    return @('Downloader.Core.ps1','AppUpdate.Core.ps1','Start-Bilibili-Download.ps1','Start-GUI.ps1','Start.bat','Start-CLI.bat','README.txt')+@(Get-VocalRuntimeFiles)+@('VERSION.txt')
}

# Keep updater usable even when Windows PowerShell cannot autoload Get-FileHash.
. (Join-Path $PSScriptRoot 'Downloader.Core.ps1')

function Get-VocalRuntimeFiles {
    return @('app.py','vocal_queue.py','gui_entry.py','suite_runtime.py','requirements.txt','vocal.ico') | ForEach-Object {'tools/vocal-remover/'+$_}
}
function Test-VocalPackage([string]$Root) {
    foreach($name in Get-VocalRuntimeFiles){if(-not [IO.File]::Exists((Join-Path $Root $name))){return $false}}
    return $true
}

function Open-ApplicationLock([string]$Root,[switch]$Exclusive) {
    $workPath=Join-Path $Root 'work'
    [void][IO.Directory]::CreateDirectory($workPath)
    $sharing=if($Exclusive){[IO.FileShare]::None}else{[IO.FileShare]::ReadWrite}
    try{return [IO.File]::Open((Join-Path $workPath 'application.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,$sharing)}
    catch [IO.IOException]{throw 'Ứng dụng đang tải, tách lời hoặc cập nhật. Đóng Vocal Remover hoặc đợi tác vụ hoàn tất rồi thử lại.'}
}

function Get-AppUpdatePlan($Release,[string]$InstalledVersion,[switch]$Repair) {
    if($Release.draft -or $Release.prerelease -or $Release.tag_name -notmatch '^v(\d+\.\d+\.\d+)$'){throw 'Phiên bản phát hành trên GitHub không hợp lệ.'}
    $version=$Matches[1]
    if([version]$version -lt [version]$InstalledVersion -or ([version]$version -eq [version]$InstalledVersion -and -not $Repair)){return [pscustomobject]@{Available=$false;Version=$InstalledVersion}}
    $name="Bilibili-Downloader-Windows-$version.zip"
    $base="https://github.com/QuanVu512/downloader-video/releases/download/v$version/"
    $zip=@($Release.assets | Where-Object {$_.name -ceq $name})
    $sum=@($Release.assets | Where-Object {$_.name -ceq ($name+'.sha256')})
    if($zip.Count -ne 1 -or $sum.Count -ne 1 -or $zip[0].browser_download_url -cne ($base+$name) -or $sum[0].browser_download_url -cne ($base+$name+'.sha256')){throw 'Bản phát hành thiếu ZIP/checksum hoặc địa chỉ không thuộc repo ứng dụng.'}
    return [pscustomobject]@{Available=$true;Version=$version;Name=$name;ZipUrl=$zip[0].browser_download_url;ChecksumUrl=$sum[0].browser_download_url}
}

function Copy-AppFileAtomic([string]$Source,[string]$Destination) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))
    $temp=$Destination+'.update-'+[Guid]::NewGuid().ToString('N')+'.tmp'
    $swapBackup=$temp+'.old'
    try{
        [IO.File]::Copy($Source,$temp,$false)
        if([IO.File]::Exists($Destination)){[IO.File]::Replace($temp,$Destination,$swapBackup)}
        else{[IO.File]::Move($temp,$Destination)}
    }finally{foreach($ownFile in @($temp,$swapBackup)){if([IO.File]::Exists($ownFile)){[IO.File]::Delete($ownFile)}}}
}

function Install-AppPackage([string]$Root,[string]$PackagePath,[string]$ExpectedHash,[string]$ExpectedVersion) {
    if($ExpectedHash -notmatch '^[0-9a-fA-F]{64}$' -or (Get-FileSha256 -LiteralPath $PackagePath) -ne $ExpectedHash){throw 'SHA-256 bản cập nhật không khớp; giữ nguyên ứng dụng hiện tại.'}
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
            if($relative.StartsWith('tools/') -and $relative -cnotin $runtime){continue} # Preserve third-party tools and local Python environments.
            if($relative -cnotin $runtime -or $entry.Length -gt 2MB){throw "Tệp không hợp lệ trong bản cập nhật: $relative"}
            $inputStream=$entry.Open()
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName((Join-Path $candidate $relative)))
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
        if([IO.File]::Exists($old)){
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName((Join-Path $backup $name)))
            [IO.File]::Copy($old,(Join-Path $backup $name),$false)
        }
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

function Invoke-AppUpdate([string]$Root,[switch]$RepairVocal) {
    $version=(Get-Content -LiteralPath (Join-Path $Root 'VERSION.txt') -TotalCount 1).Trim()
    try{$release=Invoke-RestMethod -Uri 'https://api.github.com/repos/QuanVu512/downloader-video/releases/latest' -Headers @{'User-Agent'='Bilibili-Downloader';Accept='application/vnd.github+json'} -TimeoutSec 30}
    catch{throw 'Không lấy được bản phát hành ứng dụng. Kiểm tra kết nối và trang GitHub Releases của QuanVu512/downloader-video.'}
    $repair=$RepairVocal -and -not (Test-VocalPackage $Root)
    $plan=Get-AppUpdatePlan $release $version -Repair:$repair
    if(-not $plan.Available){return [pscustomobject]@{Updated=$false;Version=$version}}
    $folder=Join-Path (Join-Path $Root 'work') ('app-download-'+[Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($folder)
    $zipPath=Join-Path $folder $plan.Name;$sumPath=$zipPath+'.sha256'
    Invoke-WebRequest -UseBasicParsing -Uri $plan.ChecksumUrl -OutFile $sumPath -TimeoutSec 60
    $checksum=[IO.File]::ReadAllText($sumPath).Trim()
    if($checksum -notmatch ('^([a-fA-F0-9]{64})\s+\*?'+[regex]::Escape($plan.Name)+'$')){throw 'Checksum phát hành không hợp lệ.'}
    $expected=$Matches[1]
    # The 2.3 updater keeps its ZIP but skips module files. Validate it against a
    # freshly fetched checksum before reusing it to complete the module install.
    $cached=Get-ChildItem -LiteralPath (Join-Path $Root 'work') -Filter $plan.Name -File -Recurse | Where-Object {
        (Get-FileSha256 -LiteralPath $_.FullName) -eq $expected
    } | Select-Object -First 1
    if($cached){$zipPath=$cached.FullName}else{Invoke-WebRequest -UseBasicParsing -Uri $plan.ZipUrl -OutFile $zipPath -TimeoutSec 180}
    return (Install-AppPackage $Root $zipPath $expected $plan.Version)
}

function Get-VocalDataRoot([string]$Root) {
    $setting=Join-Path $Root 'work/vocal-data-root.txt'
    if([IO.File]::Exists($setting)){
        $path=[IO.File]::ReadAllText($setting).Trim()
        if([IO.Directory]::Exists($path)){return [IO.Path]::GetFullPath($path)}
    }
    return $Root
}

function Get-VocalPython([string]$Root) {
    $requirements=Join-Path $Root 'tools/vocal-remover/requirements.txt'
    $owned=Join-Path $Root 'tools/vocal-runtime/.venv/Scripts/python.exe'
    $legacy=Join-Path (Split-Path $Root) 'vocal-remover/.venv/Scripts/python.exe'
    $verify=@'
import importlib.metadata as m,sys
try:
    lines=open(sys.argv[1],encoding='utf-8-sig').read().splitlines()
    ok=all(m.version(line.split('==')[0])==line.split('==')[1] for line in lines if line.strip() and not line.startswith('#'))
except Exception:
    ok=False
sys.exit(0 if ok else 1)
'@
    foreach($candidate in @($owned,$legacy)){
        if([IO.File]::Exists($candidate)){
            & $candidate -c $verify $requirements
            if($LASTEXITCODE -eq 0){return $candidate}
        }
    }
    $python=Get-Command python.exe -ErrorAction SilentlyContinue
    if(-not $python){throw 'Cần Python 3.12 64-bit để chạy Vocal Remover. Cài Python rồi mở lại nút Vocal Remover.'}
    & $python.Source -c 'import sys;sys.exit(0 if sys.version_info[:2]==(3,12) and sys.maxsize>2**32 else 1)'
    if($LASTEXITCODE -ne 0){throw 'Vocal Remover cần Python 3.12 64-bit; bản Python mặc định hiện tại chưa phù hợp.'}
    $environment=Join-Path $Root 'tools/vocal-runtime/.venv'
    $setupDirectory=Join-Path $Root 'tools/vocal-runtime'
    [void][IO.Directory]::CreateDirectory($setupDirectory)
    try{$setupLock=[IO.File]::Open((Join-Path $setupDirectory 'setup.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch [IO.IOException]{throw 'Cửa sổ khác đang chuẩn bị thư viện Vocal. Đợi tác vụ đó rồi mở lại.'}
    try{
    if([IO.File]::Exists($owned)){
        & $owned -c $verify $requirements
        if($LASTEXITCODE -eq 0){return $owned}
    }
    Write-Host 'Lần đầu mở: đang chuẩn bị thư viện tách lời; các lần sau dùng lại.'
    & $python.Source -m venv $environment
    if($LASTEXITCODE -ne 0){throw 'Không tạo được môi trường Vocal Remover.'}
    & $owned -m pip install --disable-pip-version-check -r $requirements | ForEach-Object {Write-Host $_}
    if($LASTEXITCODE -ne 0){throw 'Không cài được thư viện Vocal Remover. Kiểm tra mạng rồi bấm mở lại.'}
    & $owned -c $verify $requirements
    if($LASTEXITCODE -ne 0){throw 'Thư viện Vocal Remover chưa đủ; thử mở lại sau khi kiểm tra mạng.'}
    return $owned
    }finally{$setupLock.Dispose()}
}
