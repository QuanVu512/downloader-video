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
foreach($name in Get-AppRuntimeFiles){Copy-Item -LiteralPath (Join-Path $root $name) -Destination $app}
if(-not (Test-Path -LiteralPath (Join-Path $root 'tools/yt-dlp.exe'))){throw 'Missing tools. Run with -SetupTools.'}
if(-not (Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Recurse -Filter aria2c.exe -File)){throw 'Missing aria2.'}
Copy-Item -LiteralPath (Join-Path $root 'tools') -Destination (Join-Path $app 'tools') -Recurse
$zip=Join-Path $output ("Bilibili-Downloader-Windows-$version.zip")
Compress-Archive -LiteralPath $app -DestinationPath $zip -Force
$hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($zip+'.sha256',$hash+'  '+[IO.Path]::GetFileName($zip)+[Environment]::NewLine)
@{zip=$zip;sha256=$hash;version=$version}|ConvertTo-Json -Compress
