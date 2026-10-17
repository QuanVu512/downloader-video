param([switch]$SetupTools,[string]$OutputDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
. (Join-Path $root 'AppUpdate.Core.ps1')
$version=(Get-Content -LiteralPath (Join-Path $root 'VERSION.txt') -TotalCount 1).Trim()
if($version -notmatch '^\d+\.\d+\.\d+$'){throw 'Invalid VERSION.txt'}
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root 'dist'}
$output=[IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($output)
if($SetupTools){
    & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Start-Bilibili-Download.ps1') -SetupOnly
    if($LASTEXITCODE -ne 0){throw 'Tool setup failed'}
}
$stage=Join-Path (Join-Path $root 'work') ('release-'+[Guid]::NewGuid().ToString('N'))
$app=Join-Path $stage 'Bilibili-Downloader'
[void][IO.Directory]::CreateDirectory($app)
foreach($name in Get-AppRuntimeFiles){
    $target=Join-Path $app $name
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination $target
}
if(-not (Test-Path -LiteralPath (Join-Path $root 'tools/yt-dlp.exe'))){throw 'Missing tools. Run with -SetupTools.'}
if(-not (Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Recurse -Filter aria2c.exe -File)){throw 'Missing aria2.'}
Copy-Item -LiteralPath (Join-Path $root 'tools/yt-dlp.exe') -Destination (Join-Path $app 'tools/yt-dlp.exe')
$aria=Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Recurse -Filter aria2c.exe -File | Select-Object -First 1
$ariaTarget=Join-Path $app 'tools/aria2/aria2c.exe'
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ariaTarget))
Copy-Item -LiteralPath $aria.FullName -Destination $ariaTarget
foreach($license in Get-ChildItem -LiteralPath $aria.DirectoryName -File | Where-Object {$_.Name -ne 'aria2c.exe'}){
    Copy-Item -LiteralPath $license.FullName -Destination (Join-Path (Split-Path $ariaTarget) $license.Name)
}
if(Test-Path -LiteralPath (Join-Path $root 'tools/SHA2-256SUMS')){Copy-Item -LiteralPath (Join-Path $root 'tools/SHA2-256SUMS') -Destination (Join-Path $app 'tools/SHA2-256SUMS')}
$zip=Join-Path $output ("Bilibili-Downloader-Windows-$version.zip")
Compress-Archive -LiteralPath $app -DestinationPath $zip -Force
$hash=(Get-FileSha256 -LiteralPath $zip).ToLowerInvariant()
[IO.File]::WriteAllText($zip+'.sha256',$hash+'  '+[IO.Path]::GetFileName($zip)+[Environment]::NewLine)
@{zip=$zip;sha256=$hash;version=$version}|ConvertTo-Json -Compress
