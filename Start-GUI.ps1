$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$root = $PSScriptRoot
. (Join-Path $root 'Downloader.Core.ps1')
$workerScript = Join-Path $root 'Start-Bilibili-Download.ps1'
$workDir = Join-Path $root 'work'
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$script:worker = $null
$script:statePath = $null
$script:mode = ''
$script:lastMessage = ''
$script:lastLogText = ''
$script:lastPercent = -1
$script:choices = @()
$script:qualityUrl = ''
$script:outTask = $null
$script:errTask = $null
$script:stopRequested = $false
$script:downloadComplete = $false
$script:completedDirectory = ''

$navy = [Drawing.Color]::FromArgb(24, 38, 62)
$blue = [Drawing.Color]::FromArgb(38, 108, 210)
$pale = [Drawing.Color]::FromArgb(244, 247, 252)
$ink = [Drawing.Color]::FromArgb(40, 52, 70)
$muted = [Drawing.Color]::FromArgb(103, 117, 137)

function New-Label([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [int]$size = 10, [bool]$bold = $false) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $text; $label.Location = New-Object Drawing.Point($x, $y); $label.Size = New-Object Drawing.Size($w, $h)
    $label.ForeColor = $ink
    $style = if ($bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    $label.Font = New-Object Drawing.Font('Segoe UI', $size, $style)
    return $label
}
function New-TextBox([int]$x, [int]$y, [int]$w, [int]$h = 34) {
    $box = New-Object Windows.Forms.TextBox
    $box.Location = New-Object Drawing.Point($x, $y); $box.Size = New-Object Drawing.Size($w, $h)
    $box.Font = New-Object Drawing.Font('Segoe UI', 10)
    return $box
}
function New-Button([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [bool]$primary = $false) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $text; $button.Location = New-Object Drawing.Point($x, $y); $button.Size = New-Object Drawing.Size($w, $h)
    $button.FlatStyle = [Windows.Forms.FlatStyle]::Flat; $button.FlatAppearance.BorderSize = 0
    $button.BackColor = if ($primary) { $blue } else { [Drawing.Color]::FromArgb(230, 236, 245) }
    $button.ForeColor = if ($primary) { [Drawing.Color]::White } else { $ink }
    $button.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
    $button.Cursor = [Windows.Forms.Cursors]::Hand
    return $button
}

$form = New-Object Windows.Forms.Form
$form.Text = 'Bilibili Downloader '+(Get-Content -LiteralPath (Join-Path $root 'VERSION.txt') -TotalCount 1).Trim()
$form.ClientSize = New-Object Drawing.Size(920, 690)
$form.MinimumSize = New-Object Drawing.Size(780, 650)
$form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor = $pale
$form.Font = New-Object Drawing.Font('Segoe UI', 10)

$header = New-Object Windows.Forms.Panel
$header.Dock = [Windows.Forms.DockStyle]::Top; $header.Height = 86; $header.BackColor = $navy
$title = New-Label 'Bilibili Downloader' 28 16 280 32 18 $true
$title.ForeColor = [Drawing.Color]::White
$subtitle = New-Label 'Video, âm thanh và ZIP cho CapCut' 30 51 280 22 9 $false
$subtitle.ForeColor = [Drawing.Color]::FromArgb(202, 215, 233)
$header.Controls.AddRange(@($title, $subtitle))

$content = New-Object Windows.Forms.Panel
$content.Dock = [Windows.Forms.DockStyle]::Fill; $content.Padding = New-Object Windows.Forms.Padding(28, 20, 28, 20)
$form.Controls.Add($content)
$form.Controls.Add($header)
$updateButton = New-Button 'Cập nhật yt-dlp' 470 23 190 36 $false
$updateButton.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
$header.Controls.Add($updateButton)
$appUpdateButton = New-Button 'Cập nhật ứng dụng' 675 23 210 36 $false
$appUpdateButton.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
$header.Controls.Add($appUpdateButton)

$content.Controls.Add((New-Label '1. Link video' 0 0 180 24 10 $true))
$urlBox = New-TextBox 0 28 656
$urlBox.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
$urlBox.Text = ''
$getQualityButton = New-Button 'Lấy chất lượng' 670 27 194 36 $false
$getQualityButton.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
$content.Controls.AddRange(@($urlBox, $getQualityButton))

$content.Controls.Add((New-Label '2. Chọn chất lượng video' 0 82 250 24 10 $true))
$qualityBox = New-Object Windows.Forms.ComboBox
$qualityBox.Location = New-Object Drawing.Point(0, 110); $qualityBox.Size = New-Object Drawing.Size(530, 36)
$qualityBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
$qualityBox.Font = New-Object Drawing.Font('Segoe UI', 10)
$qualityBox.Enabled = $false
$qualityHint = New-Label 'Danh sách sẽ tùy theo video bạn dán.' 548 112 320 26 9 $false
$qualityHint.ForeColor = $muted
$content.Controls.AddRange(@($qualityBox, $qualityHint))

$content.Controls.Add((New-Label '3. Đặt tên file' 0 164 220 24 10 $true))
$nameBox = New-TextBox 0 192 410
$nameBox.Text = 'bilibili_video'
$content.Controls.Add($nameBox)
$content.Controls.Add((New-Label 'Video: <tên>_video.mp4   |   Âm thanh: <tên>_audio.m4a' 426 198 440 24 9 $false))
$content.Controls[$content.Controls.Count - 1].ForeColor = $muted

$content.Controls.Add((New-Label '4. Thư mục lưu' 0 246 220 24 10 $true))
$folderBox = New-TextBox 0 274 730
$folderBox.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
$folderBox.Text = [Environment]::GetFolderPath('MyVideos')
$browseButton = New-Button 'Chọn thư mục' 744 273 120 36 $false
$browseButton.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
$content.Controls.AddRange(@($folderBox, $browseButton))

$downloadButton = New-Button 'Tải video và âm thanh' 0 326 864 46 $true
$downloadButton.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
$downloadButton.Enabled = $false
$content.Controls.Add($downloadButton)

$statusLabel = New-Label 'Sẵn sàng. Dán link Bilibili rồi bấm “Lấy chất lượng”.' 0 388 864 24 10 $true
$statusLabel.AutoEllipsis = $true
$content.Controls.Add($statusLabel)
$progress = New-Object Windows.Forms.ProgressBar
$progress.Location = New-Object Drawing.Point(0, 416); $progress.Size = New-Object Drawing.Size(864, 14)
$progress.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
$progress.Style = [Windows.Forms.ProgressBarStyle]::Continuous
$content.Controls.Add($progress)

$logLabel = New-Label 'Hoạt động' 0 447 200 24 10 $true
$content.Controls.Add($logLabel)
$openFolderButton = New-Button 'Mở thư mục chứa tệp' 660 447 204 26 $false
$openFolderButton.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
$openFolderButton.Enabled = $false
$content.Controls.Add($openFolderButton)
$logBox = New-Object Windows.Forms.RichTextBox
$logBox.Location = New-Object Drawing.Point(0, 475); $logBox.Size = New-Object Drawing.Size(864, 120)
$logBox.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Bottom -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
$logBox.ReadOnly = $true; $logBox.BackColor = [Drawing.Color]::White; $logBox.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$logBox.Font = New-Object Drawing.Font('Consolas', 9)
$content.Controls.Add($logBox)
$footer = New-Label 'Chất lượng cao hơn chỉ hiện khi Bilibili cung cấp cho quyền truy cập hiện tại.' 0 610 645 24 9 $false
$footer.ForeColor = $muted
$footer.Anchor = [Windows.Forms.AnchorStyles]::Bottom -bor [Windows.Forms.AnchorStyles]::Left
$content.Controls.Add($footer)
$stopButton = New-Button 'Dừng / giữ phần dở' 660 607 204 30 $false
$stopButton.Anchor = [Windows.Forms.AnchorStyles]::Bottom -bor [Windows.Forms.AnchorStyles]::Right
$stopButton.Enabled = $false
$content.Controls.Add($stopButton)

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 400

function Add-Log([string]$text) {
    $safeText = Protect-DownloadLog $text
    if ($safeText -eq $script:lastLogText) { return }
    $script:lastLogText = $safeText
    $logBox.AppendText((Get-Date -Format 'HH:mm:ss') + '  ' + $safeText + [Environment]::NewLine)
    if ($logBox.TextLength -gt 180000) { $logBox.Text = $logBox.Text.Substring($logBox.TextLength - 120000) }
    $logBox.SelectionStart = $logBox.TextLength; $logBox.ScrollToCaret()
}
function Quote-ProcessArgument([string]$value) {
    $escaped = $value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}
function Start-DownloaderWorker([string]$workerMode, [string[]]$arguments) {
    $script:statePath = Join-Path $workDir ([guid]::NewGuid().ToString('N') + '.json')
    $baseArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $workerScript) + $arguments + @('-Url', $urlBox.Text.Trim(), '-StateFile', $script:statePath)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = (($baseArgs | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join ' ')
    $psi.WorkingDirectory = $root; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $script:worker = New-Object Diagnostics.Process
    $script:worker.StartInfo = $psi
    [void]$script:worker.Start()
    $script:outTask = $script:worker.StandardOutput.ReadLineAsync()
    $script:errTask = $script:worker.StandardError.ReadLineAsync()
    $script:mode = $workerMode; $script:lastMessage = ''; $script:lastPercent = -1
    $script:stopRequested = $false
    $script:downloadComplete = $false
    $script:completedDirectory = ''
    Set-UiBusy $true
    $timer.Start()
}

function Set-UiBusy([bool]$busy) {
    foreach ($control in @($urlBox, $nameBox, $folderBox, $browseButton, $getQualityButton, $updateButton, $appUpdateButton)) { $control.Enabled = -not $busy }
    $qualityBox.Enabled = -not $busy -and $script:choices.Count -gt 0
    $downloadButton.Enabled = -not $busy -and $script:choices.Count -gt 0 -and -not $script:downloadComplete
    $downloadButton.Text = if ($script:downloadComplete) { 'Đã tải xong' } else { 'Tải video và âm thanh' }
    $openFolderButton.Enabled = -not $busy -and $script:downloadComplete
    $stopButton.Enabled = $busy
}
function Reset-CompletedDownload {
    if ($script:worker) { return }
    $script:downloadComplete = $false
    $script:completedDirectory = ''
    Set-UiBusy $false
}
$nameBox.Add_TextChanged({ Reset-CompletedDownload })
$folderBox.Add_TextChanged({ Reset-CompletedDownload })
$qualityBox.Add_SelectedIndexChanged({ Reset-CompletedDownload })
$openFolderButton.Add_Click({
    if ($script:downloadComplete -and [IO.Directory]::Exists($script:completedDirectory)) {
        Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList (Quote-ProcessArgument $script:completedDirectory)
    }
})
function Start-WorkerSafely([string]$mode, [string[]]$workerArgs) {
    try { Start-DownloaderWorker $mode $workerArgs }
    catch { Set-UiBusy $false; $statusLabel.Text = 'Không khởi động được tác vụ.'; Add-Log $_.Exception.Message }
}
$urlBox.Add_TextChanged({
    if ($script:worker) { return }
    $script:qualityUrl = ''; $script:choices = @()
    $qualityBox.Items.Clear(); $qualityBox.Enabled = $false; $downloadButton.Enabled = $false
    $qualityHint.Text = 'Link đã đổi. Bấm Lấy chất lượng.'
    Reset-CompletedDownload
})
$updateButton.Add_Click({ Start-WorkerSafely 'setup' @('-SetupOnly', '-UpdateTools') })
$appUpdateButton.Add_Click({ Start-WorkerSafely 'app-update' @('-UpdateApp') })
$stopButton.Add_Click({
    if ($script:worker -and -not $script:worker.HasExited) {
        $script:stopRequested = $true; $stopButton.Enabled = $false
        Start-Process -FilePath (Join-Path $env:WINDIR 'System32\taskkill.exe') -ArgumentList @('/PID', [string]$script:worker.Id, '/T', '/F') -WindowStyle Hidden -Wait
        Add-Log 'Đã yêu cầu dừng. Phần dở được giữ để tải tiếp với cùng thông tin.'
    }
})

$getQualityButton.Add_Click({
    if ($script:worker -and -not $script:worker.HasExited) { return }
    try { $null = ConvertTo-BilibiliUrl $urlBox.Text } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Link chưa hợp lệ', 'OK', 'Information') | Out-Null; return }
    $script:choices = @(); $script:qualityUrl = ''
    $qualityBox.Items.Clear(); $qualityBox.Enabled = $false; $downloadButton.Enabled = $false
    $getQualityButton.Enabled = $false; $progress.Value = 0; $statusLabel.Text = 'Đang lấy danh sách chất lượng...'
    Add-Log 'Đang đọc các định dạng video Bilibili.'
    Start-WorkerSafely 'inspect' @('-ListQualities')
})

$downloadButton.Add_Click({
    if ($script:worker -and -not $script:worker.HasExited) { return }
    if ($script:downloadComplete) { return }
    if ($qualityBox.SelectedIndex -lt 0) { return }
    try { if ((ConvertTo-BilibiliUrl $urlBox.Text) -ne $script:qualityUrl) { throw 'Link đã đổi. Bấm Lấy chất lượng lại trước khi tải.' } }
    catch { Add-Log $_.Exception.Message; $downloadButton.Enabled = $false; return }
    if ([string]::IsNullOrWhiteSpace($nameBox.Text)) {
        [Windows.Forms.MessageBox]::Show('Nhập tên cơ sở cho hai file trước khi tải.', 'Thiếu tên file', 'OK', 'Warning') | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($folderBox.Text)) {
        [Windows.Forms.MessageBox]::Show('Chọn thư mục để lưu hai file.', 'Thiếu thư mục', 'OK', 'Warning') | Out-Null
        return
    }
    $selected = $script:choices[$qualityBox.SelectedIndex]
    $workerArgs = @('-VideoFormatId', [string]$selected.format_id, '-FileName', $nameBox.Text.Trim(), '-OutputDirectory', $folderBox.Text.Trim())
    $getQualityButton.Enabled = $false; $downloadButton.Enabled = $false; $progress.Value = 0
    $statusLabel.Text = 'Đang chuẩn bị tải...'; Add-Log ("Bắt đầu tải {0}." -f $selected.label)
    Start-WorkerSafely 'download' $workerArgs
})

$browseButton.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Chọn thư mục lưu video và âm thanh'
    $dialog.SelectedPath = $folderBox.Text
    if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $folderBox.Text = $dialog.SelectedPath }
})

function Drain-WorkerPipe([string]$name) {
    $task = Get-Variable -Name $name -Scope Script -ValueOnly
    for ($i=0; $i -lt 100 -and $null -ne $task -and $task.IsCompleted; $i++) {
        try { $line=$task.GetAwaiter().GetResult() } catch { $line=$null }
        if ($null -eq $line) { $task=$null; break }
        if (-not [string]::IsNullOrWhiteSpace($line) -and $line -ne $script:lastMessage) {
            Add-Log (Protect-DownloadLog $line)
        }
        $task=if($name -eq 'outTask'){$script:worker.StandardOutput.ReadLineAsync()}else{$script:worker.StandardError.ReadLineAsync()}
    }
    Set-Variable -Name $name -Scope Script -Value $task
}
$timer.Add_Tick({
    if ($script:worker) { Drain-WorkerPipe 'outTask'; Drain-WorkerPipe 'errTask' }
    if ($script:statePath -and (Test-Path -LiteralPath $script:statePath)) {
        try {
            $state=Read-SharedJson $script:statePath
            # Final state can arrive before stdout has drained its older lines.
            $deferComplete=$state.status -eq 'complete' -and ($null -ne $script:outTask -or $null -ne $script:errTask)
            if($state.message -and $state.message -ne $script:lastMessage -and -not $deferComplete){
                $statusLabel.Text=$state.message;Add-Log $state.message;$script:lastMessage=$state.message
            }
            if($state.percent -ge 0 -and $state.percent -le 100){$progress.Value=[int]$state.percent;$script:lastPercent=[int]$state.percent}
            if($script:mode -eq 'inspect' -and $state.status -eq 'ready' -and $state.choices -and $qualityBox.Items.Count -eq 0){
                $script:choices=@($state.choices);$script:qualityUrl=$script:choices[0].url
                foreach($item in $script:choices){[void]$qualityBox.Items.Add($item.label)}
                $qualityBox.SelectedIndex=0
                $qualityHint.Text=("Tìm thấy {0} mức; đang chọn mức cao nhất." -f $script:choices.Count)
                if($nameBox.Text -eq 'bilibili_video' -or [string]::IsNullOrWhiteSpace($nameBox.Text)){
                    $canonical=[uri]$script:qualityUrl
                    $nameBox.Text=$canonical.AbsolutePath.Trim('/').Split('/')[-1]+'_p'+([regex]::Match($canonical.Query,'p=(\d+)')).Groups[1].Value
                }
            }
        }catch{}
    }
    if($script:worker -and $script:worker.HasExited -and $null -eq $script:outTask -and $null -eq $script:errTask){
        $timer.Stop();$code=$script:worker.ExitCode
        $script:worker.Dispose();$script:worker=$null
        Set-UiBusy $false
        if($script:stopRequested){$statusLabel.Text='Đã dừng. Bấm tải lại cùng thông tin để tiếp tục phần dở.'}
        elseif($code -ne 0){
            if($script:lastMessage -notmatch '^Lỗi:'){$statusLabel.Text='Có lỗi. Xem chi tiết trong Hoạt động.';Add-Log ("Tác vụ kết thúc do lỗi (mã {0})." -f $code)}
        }elseif($script:mode -eq 'download'){
            $script:downloadComplete=$true
            $script:completedDirectory=$folderBox.Text.Trim()
            $statusLabel.Text='Đã tải xong và tạo ZIP cho CapCut. Bấm Mở thư mục chứa tệp.';$progress.Value=100
            Set-UiBusy $false
        }elseif($script:mode -eq 'setup'){
            $statusLabel.Text='Công cụ đã cập nhật. Bấm Lấy chất lượng cho video cần tải.'
            $script:choices=@();$qualityBox.Items.Clear();Set-UiBusy $false
        }elseif($script:mode -eq 'app-update'){
            $installed=(Get-Content -LiteralPath (Join-Path $root 'VERSION.txt') -TotalCount 1).Trim()
            if($form.Text -ne ('Bilibili Downloader '+$installed)){
                Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -ArgumentList ((@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'Start-GUI.ps1')) | ForEach-Object {Quote-ProcessArgument $_}) -join ' ')
                $form.Close()
            }else{$statusLabel.Text=$script:lastMessage}
        }elseif($qualityBox.Items.Count -eq 0){$statusLabel.Text='Không nhận được chất lượng. Xem Hoạt động để biết nguyên nhân.'}
        $script:mode=''
    }
})
$form.Add_FormClosing({
    if ($script:worker -and -not $script:worker.HasExited) {
        $_.Cancel = $true
        [Windows.Forms.MessageBox]::Show('Tác vụ đang chạy. Bấm Dừng / giữ phần dở rồi đóng cửa sổ, hoặc đợi tải xong.', 'Đang tải', 'OK', 'Information') | Out-Null
    }
})

[void]$form.ShowDialog()
