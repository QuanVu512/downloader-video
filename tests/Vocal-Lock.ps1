param([string]$AppPath,[string]$Python)
$ErrorActionPreference='Stop'
. (Join-Path $AppPath 'AppUpdate.Core.ps1')
. (Join-Path $AppPath 'Downloader.Core.ps1')
$code=@'
from suite_runtime import use_lock
import sys
with use_lock():
    print('LOCKED',flush=True)
    sys.stdin.readline()
'@
$psi=New-Object Diagnostics.ProcessStartInfo
$psi.FileName=$Python
$psi.Arguments=((@('-u','-c',$code) | ForEach-Object {Quote-ProcessArgument $_}) -join ' ')
$psi.WorkingDirectory=Join-Path $AppPath 'tools/vocal-remover'
$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.RedirectStandardInput=$true
$process=New-Object Diagnostics.Process
$process.StartInfo=$psi
$lock=$null
try{
    [void]$process.Start()
    $task=$process.StandardOutput.ReadLineAsync()
    if(-not $task.Wait(15000) -or $task.Result -ne 'LOCKED'){throw 'Python did not acquire the application lock.'}
    $blocked=$false
    try{$lock=Open-ApplicationLock $AppPath -Exclusive}catch{$blocked=$true}
    if(-not $blocked){throw 'Updater was not blocked while Python was active.'}
    Write-Host 'PASS Python Vocal process blocks application update'
}finally{
    if($lock){$lock.Dispose()}
    if($process.Id -and -not $process.HasExited){$process.StandardInput.WriteLine('done');if(-not $process.WaitForExit(15000)){$process.Kill()}}
    $process.Dispose()
}
$lock=Open-ApplicationLock $AppPath -Exclusive
try{
    $code=@'
from suite_runtime import use_lock
import sys
try:
    with use_lock():
        pass
except RuntimeError:
    sys.exit(0)
sys.exit(1)
'@
    Push-Location (Join-Path $AppPath 'tools/vocal-remover')
    try{& $Python -c $code;if($LASTEXITCODE -ne 0){throw 'Python entered while updater held exclusive lock.'}}finally{Pop-Location}
    Write-Host 'PASS Application update blocks new Vocal process'
}finally{$lock.Dispose()}
