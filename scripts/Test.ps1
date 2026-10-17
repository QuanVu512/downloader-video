$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
foreach($file in Get-ChildItem -LiteralPath $root -File -Filter '*.ps1'){
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw "$($file.Name): $($errors[0].Message)"}
}
python (Join-Path $root 'tests/fixtures.py')
if($LASTEXITCODE -ne 0){throw 'Fixture generation failed'}
$powershell=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
foreach($test in @('Regression.ps1','Zip-Regression.ps1','Update-Regression.ps1','Hash-Regression.ps1')){
    & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root ('tests/'+$test)) -AppPath $root
    if($LASTEXITCODE -ne 0){throw "Failed $test"}
}
python (Join-Path $root 'tests/integration.py')
if($LASTEXITCODE -ne 0){throw 'HTTP integration failed'}
if($env:VOCAL_TEST_PYTHON){$vocalPython=$env:VOCAL_TEST_PYTHON}else{$vocalPython=(Get-Command python).Source}
& $vocalPython -m unittest discover -s (Join-Path $root 'tools/vocal-remover') -v
if($LASTEXITCODE -ne 0){throw 'Vocal tests failed'}
& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests/Vocal-Lock.ps1') -AppPath $root -Python $vocalPython
if($LASTEXITCODE -ne 0){throw 'Cross-process vocal update lock test failed'}
& $powershell -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $root 'Start-GUI.ps1') -SmokeTest
if($LASTEXITCODE -ne 0){throw 'Integrated GUI smoke test failed'}
