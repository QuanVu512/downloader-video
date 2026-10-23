param([string]$AppPath)
$ErrorActionPreference='Stop'
. (Join-Path $AppPath 'Downloader.Core.ps1')
$work=Join-Path $PSScriptRoot ('work/bilibili-'+[Guid]::NewGuid().ToString('N'))
$plugins=Initialize-BilibiliPlugin $work
$plugin=Join-Path $plugins 'bilibili/yt_dlp_plugins/extractor/bilibili_compat.py'
python (Join-Path $PSScriptRoot 'bilibili_compat_test.py') $plugin
if($LASTEXITCODE -ne 0){throw 'Bilibili compatibility tests failed'}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $AppPath 'Start-Bilibili-Download.ps1'),[ref]$null,[ref]$null)
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-BilibiliSession'},$true)
Invoke-Expression $fn.Extent.Text
function Set-DownloaderState {}
function Invoke-DownloaderProcess {
    param($Executable,$Directory,$TimeoutSeconds,$Arguments)
    $index=[Array]::IndexOf($Arguments,'--plugin-dirs')
    if($index -lt 0 -or '--no-plugin-dirs' -notin $Arguments){throw 'Worker must explicitly select its own plugin directory'}
    $actual=Join-Path $Arguments[$index+1] 'bilibili/yt_dlp_plugins/extractor/bilibili_compat.py'
    if(-not [IO.File]::Exists($actual)){throw 'Worker plugin missing from its scratch directory'}
    if($Arguments[-1] -ne $Url){throw 'Worker changed canonical URL/part'}
    return [pscustomobject]@{ExitCode=0;StdOut=@('{"formats":[{"format_id":"video"}]}');StdErr=@()}
}
$scratch=$work;$bin=[pscustomobject]@{YtDlp='fixture'};$Url='https://www.bilibili.com/video/BV1iWJv6GEvX/?p=3'
$session=Get-BilibiliSession
if($session.Info.formats[0].format_id -ne 'video'){throw 'Worker lost extracted formats'}
if((Get-DownloadErrorHint 'Unable to extract initial state') -notmatch 'Cập nhật ứng dụng'){throw 'Missing app update guidance'}
Write-Host 'PASS worker generates and selects compatibility plugin while preserving video part'
