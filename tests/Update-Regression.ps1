param([string]$AppPath)
$ErrorActionPreference='Stop'
. (Join-Path $AppPath 'AppUpdate.Core.ps1')
. (Join-Path $AppPath 'Downloader.Core.ps1')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$work=Join-Path $PSScriptRoot ('work/update-tests-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$passed=0
function Assert($condition,[string]$label){if(-not $condition){throw "FAIL $label"};$script:passed++;Write-Host "PASS $label"}
function Fresh-Root([switch]$Legacy) {
    $path=Join-Path $work ([Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($path)
    foreach($name in Get-AppRuntimeFiles){
        if($Legacy -and $name.StartsWith('tools/')){continue}
        $target=Join-Path $path $name
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::Copy((Join-Path $AppPath $name),$target)
    }
    [IO.File]::WriteAllText((Join-Path $path 'VERSION.txt'),'2.3.0')
    [void][IO.Directory]::CreateDirectory((Join-Path $path 'tools'));[void][IO.Directory]::CreateDirectory((Join-Path $path 'work'))
    [IO.File]::WriteAllText((Join-Path $path 'tools/keep.txt'),'installed tool')
    [IO.File]::WriteAllText((Join-Path $path 'work/keep.txt'),'local state')
    [IO.File]::WriteAllText((Join-Path $path 'media.native.part'),'partial data')
    if(-not $Legacy){[IO.File]::WriteAllText((Join-Path $path 'tools/vocal-remover/ui-settings.json'),'user settings')}
    return $path
}
function Make-Package([string]$ExtraPath='', [switch]$InvalidScript) {
    $path=Join-Path $work ([Guid]::NewGuid().ToString('N')+'.zip')
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew)
    $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try{
        foreach($name in Get-AppRuntimeFiles){
            $entry=$zip.CreateEntry('Bilibili-Downloader/'+$name)
            $bytes=[IO.File]::ReadAllBytes((Join-Path $AppPath $name))
            if($name -eq 'VERSION.txt'){$bytes=[Text.Encoding]::UTF8.GetBytes('9.0.0')}
            if($name -eq 'README.txt'){$bytes=[Text.Encoding]::UTF8.GetBytes('New release README')}
            if($name -eq 'Downloader.Core.ps1'){$bytes+=([Text.Encoding]::UTF8.GetBytes("`r`n# new fixture release"))}
            if($InvalidScript -and $name -eq 'Start-GUI.ps1'){$bytes+=([Text.Encoding]::UTF8.GetBytes("`r`nfunction {"))}
            $entryStream=$entry.Open()
            try{$entryStream.Write($bytes,0,$bytes.Length)}finally{$entryStream.Dispose()}
        }
        $extra=if($ExtraPath){$ExtraPath}else{'Bilibili-Downloader/tools/keep.txt'}
        $writer=New-Object IO.StreamWriter($zip.CreateEntry($extra).Open())
        try{$writer.Write('Must not overwrite local tool or escape archive root')}finally{$writer.Dispose()}
    }finally{$zip.Dispose();$stream.Dispose()}
    return $path
}
function Try-Install($root,$zip,$version='9.0.0',$hash='') {
    if(-not $hash){$hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash}
    return (Install-AppPackage $root $zip $hash $version)
}
$zip=Make-Package
$root=Fresh-Root
$result=Try-Install $root $zip
Assert ($result.Updated -and (Get-Content -LiteralPath (Join-Path $root 'VERSION.txt') -Raw).Trim() -eq '9.0.0') 'Install complete application release including version'
Assert ((Get-Content -LiteralPath (Join-Path $root 'tools/keep.txt') -Raw) -eq 'installed tool' -and (Get-Content -LiteralPath (Join-Path $root 'work/keep.txt') -Raw) -eq 'local state' -and (Get-Content -LiteralPath (Join-Path $root 'media.native.part') -Raw) -eq 'partial data') 'Application update preserves tools state and partial media'
Assert (Test-Path -LiteralPath (Join-Path $result.Backup 'VERSION.txt')) 'Previous application files retained as backup'
foreach($test in @('checksum','version','traversal','duplicate','syntax')){
    $root=Fresh-Root;$candidate=$zip;$expected='9.0.0';$hash=''
    switch($test){
        'checksum'{$hash='0'*64}
        'version'{$expected='9.0.1'}
        'traversal'{$candidate=Make-Package 'Bilibili-Downloader/../outside.txt'}
        'duplicate'{$candidate=Make-Package 'Bilibili-Downloader/downloader.core.ps1'}
        'syntax'{$candidate=Make-Package -InvalidScript}
    }
    $rejected=$false;try{$null=Try-Install $root $candidate $expected $hash}catch{$rejected=$true}
    Assert ($rejected -and (Get-Content -LiteralPath (Join-Path $root 'VERSION.txt') -Raw).Trim() -eq '2.3.0') "Reject $test without changing installed version"
}
$root=Fresh-Root;$before=@{}
foreach($name in Get-AppRuntimeFiles){$before[$name]=(Get-FileHash -LiteralPath (Join-Path $root $name) -Algorithm SHA256).Hash}
$locked=[IO.File]::Open((Join-Path $root 'Start-Bilibili-Download.ps1'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$rejected=$false
try{try{$null=Try-Install $root $zip}catch{$rejected=$true}}finally{$locked.Dispose()}
$restored=$true
foreach($name in Get-AppRuntimeFiles){if((Get-FileHash -LiteralPath (Join-Path $root $name) -Algorithm SHA256).Hash -ne $before[$name]){$restored=$false}}
Assert ($rejected -and $restored) 'Failed replacement rolls back all already replaced files'
$shared1=Open-ApplicationLock $root;$shared2=Open-ApplicationLock $root
$rejected=$false
try{try{$exclusive=Open-ApplicationLock $root -Exclusive;$exclusive.Dispose()}catch{$rejected=$true}}finally{$shared1.Dispose();$shared2.Dispose()}
Assert $rejected 'Active downloads block application update'
$exclusive=Open-ApplicationLock $root -Exclusive;$rejected=$false
try{try{$shared=Open-ApplicationLock $root;$shared.Dispose()}catch{$rejected=$true}}finally{$exclusive.Dispose()}
Assert $rejected 'Application update blocks new downloads'
$name='Bilibili-Downloader-Windows-9.0.0.zip'
$base='https://github.com/QuanVu512/downloader-video/releases/download/v9.0.0/'
$release=[pscustomobject]@{tag_name='v9.0.0';draft=$false;prerelease=$false;assets=@([pscustomobject]@{name=$name;browser_download_url=$base+$name},[pscustomobject]@{name=$name+'.sha256';browser_download_url=$base+$name+'.sha256'})}
Assert (Get-AppUpdatePlan $release '2.3.0').Available 'Higher release version selects ZIP and checksum'
Assert (-not (Get-AppUpdatePlan $release '9.0.0').Available -and -not (Get-AppUpdatePlan $release '10.0.0').Available) 'No update or downgrade when installed version is current or newer'
$release.assets[0].browser_download_url='https://example.com/untrusted.zip';$rejected=$false
try{$null=Get-AppUpdatePlan $release '2.3.0'}catch{$rejected=$true}
Assert $rejected 'Reject release assets outside configured repository'
Assert ((Get-DownloadErrorHint 'yt_dlp.utils.ThrottledDownload: The download speed is below throttle limit') -match 'ngưỡng tốc độ thấp') 'Reported throttle exception has a specific explanation'
Assert (Test-VocalPackage $root) 'Vocal module is included in the application runtime'
Assert ((Get-AppUpdatePlan ([pscustomobject]@{tag_name='v9.0.0';draft=$false;prerelease=$false;assets=@([pscustomobject]@{name=$name;browser_download_url=$base+$name},[pscustomobject]@{name=$name+'.sha256';browser_download_url=$base+$name+'.sha256'})}) '9.0.0' -Repair).Available) 'Repair can complete an equal-version module install'
$root=Fresh-Root
$result=Try-Install $root $zip
Assert ((Get-Content -LiteralPath (Join-Path $root 'tools/vocal-remover/ui-settings.json') -Raw) -eq 'user settings') 'Combined update preserves vocal settings'
$root=Fresh-Root
$before=@{};foreach($file in Get-AppRuntimeFiles){$before[$file]=(Get-FileHash -LiteralPath (Join-Path $root $file)).Hash}
$locked=[IO.File]::Open((Join-Path $root 'tools/vocal-remover/requirements.txt'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$rejected=$false
try{try{$null=Try-Install $root $zip}catch{$rejected=$true}}finally{$locked.Dispose()}
$restored=$true;foreach($file in Get-AppRuntimeFiles){if((Get-FileHash -LiteralPath (Join-Path $root $file)).Hash -ne $before[$file]){$restored=$false}}
Assert ($rejected -and $restored) 'Vocal replacement failure rolls back both application components'
$root=Fresh-Root -Legacy
. (Join-Path $PSScriptRoot 'fixtures/AppUpdate-2.3.ps1')
$null=Try-Install $root $zip
Assert ((Get-Content -LiteralPath (Join-Path $root 'VERSION.txt') -Raw).Trim() -eq '9.0.0' -and -not [IO.File]::Exists((Join-Path $root 'tools/vocal-remover/app.py'))) 'Legacy 2.3 updater safely installs the bridge and leaves module pending'
. (Join-Path $AppPath 'AppUpdate.Core.ps1')
$null=Try-Install $root $zip
Assert (Test-VocalPackage $root) 'Bridge completes the module from the same verified release package'
Write-Host "TOTAL PASS $passed"
