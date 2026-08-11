$ErrorActionPreference = "Stop"
$BaseUrl = if ($env:TUNNELPANE_URL) { $env:TUNNELPANE_URL.TrimEnd("/") } else { "__TUNNELPANE_URL__" }
$LocalDirectory = (Get-Location).Path
$ActivePane = "local"
$LocalSelected = 0
$ServerSelected = 0
$LocalOffset = 0
$ServerOffset = 0
$Status = "Ready."
$TransferWorkers = if ($env:TUNNELPANE_TRANSFERS) { [int]$env:TUNNELPANE_TRANSFERS } else { 4 }
if ($TransferWorkers -lt 1) { $TransferWorkers = 4 }
if ($TransferWorkers -gt 8) { $TransferWorkers = 8 }
$TransferPartSize = 8MB

function Get-FileId([string]$Name) {
    $value = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Name))
    return $value.TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function Format-Size([long]$Size) {
    if ($Size -lt 1KB) { return "$Size B" }
    if ($Size -lt 1MB) { return "$([Math]::Floor($Size / 1KB)) KB" }
    if ($Size -lt 1GB) { return "$([Math]::Floor($Size / 1MB)) MB" }
    return "$([Math]::Floor($Size / 1GB)) GB"
}

function Get-LocalItems {
    $items = @()
    $parent = Split-Path -Parent $LocalDirectory
    if ($parent -and $parent -ne $LocalDirectory) {
        $items += [pscustomobject]@{ Name = ".."; FullName = $parent; IsDirectory = $true; SizeLabel = "-"; Length = 0 }
    }
    try {
        $children = @(Get-ChildItem -LiteralPath $LocalDirectory -Force | Sort-Object @{ Expression = { -not $_.PSIsContainer } }, Name)
        foreach ($item in $children) {
            $name = $item.Name.Replace("`r", " ").Replace("`n", " ").Replace("`t", " ")
            if ($item.PSIsContainer) { $name += "/" }
            $items += [pscustomobject]@{
                Name = $name
                FullName = $item.FullName
                IsDirectory = [bool]$item.PSIsContainer
                SizeLabel = if ($item.PSIsContainer) { "-" } else { Format-Size $item.Length }
                Length = if ($item.PSIsContainer) { 0 } else { [long]$item.Length }
            }
        }
    } catch {
        $script:Status = "Cannot read local folder: $($_.Exception.Message)"
    }
    return @($items)
}

function Get-ServerItems {
    $result = Invoke-RestMethod -Uri "$BaseUrl/api/cli/files" -Headers $Headers -Method Get
    return @($result.files)
}

function Fit-Text([string]$Value, [int]$Width) {
    if ($null -eq $Value) { $Value = "" }
    $Value = $Value.Replace("`r", " ").Replace("`n", " ").Replace("`t", " ")
    if ($Value.Length -gt $Width) {
        if ($Width -gt 3) { $Value = $Value.Substring(0, $Width - 3) + "..." }
        else { $Value = $Value.Substring(0, $Width) }
    }
    return $Value.PadRight($Width)
}

function Clamp-Selections {
    if ($LocalItems.Count -eq 0) { $script:LocalSelected = -1; $script:LocalOffset = 0 }
    else {
        if ($LocalSelected -lt 0) { $script:LocalSelected = 0 }
        if ($LocalSelected -ge $LocalItems.Count) { $script:LocalSelected = $LocalItems.Count - 1 }
    }
    if ($ServerItems.Count -eq 0) { $script:ServerSelected = -1; $script:ServerOffset = 0 }
    else {
        if ($ServerSelected -lt 0) { $script:ServerSelected = 0 }
        if ($ServerSelected -ge $ServerItems.Count) { $script:ServerSelected = $ServerItems.Count - 1 }
    }
}

function Adjust-Offsets([int]$Rows) {
    if ($LocalSelected -ge 0) {
        if ($LocalSelected -lt $LocalOffset) { $script:LocalOffset = $LocalSelected }
        if ($LocalSelected -ge $LocalOffset + $Rows) { $script:LocalOffset = $LocalSelected - $Rows + 1 }
    }
    if ($ServerSelected -ge 0) {
        if ($ServerSelected -lt $ServerOffset) { $script:ServerOffset = $ServerSelected }
        if ($ServerSelected -ge $ServerOffset + $Rows) { $script:ServerOffset = $ServerSelected - $Rows + 1 }
    }
}

function Show-Panes {
    try { $width = [Math]::Max(64, [Console]::WindowWidth); $height = [Math]::Max(20, [Console]::WindowHeight) }
    catch { $width = 80; $height = 24 }
    $paneWidth = [Math]::Floor(($width - 1) / 2)
    $inner = $paneWidth - 2
    $rows = [Math]::Max(6, $height - 10)
    Adjust-Offsets $rows

    Clear-Host
    Write-Host (Fit-Text "TUNNELPANE  Local: $LocalDirectory" ($width - 1))
    $border = "-" * $paneWidth
    Write-Host "$border $border"
    $leftTitle = if ($ActivePane -eq "local") { ">LOCAL" } else { " LOCAL" }
    $rightTitle = if ($ActivePane -eq "server") { ">SERVER" } else { " SERVER" }
    Write-Host "|$(Fit-Text $leftTitle $inner)| |$(Fit-Text "$rightTitle  $($ServerItems.Count) file(s)" $inner)|"

    for ($row = 0; $row -lt $rows; $row++) {
        $li = $LocalOffset + $row
        $si = $ServerOffset + $row
        $left = ""
        $right = ""
        if ($li -lt $LocalItems.Count) {
            $marker = if ($li -eq $LocalSelected) { if ($ActivePane -eq "local") { ">" } else { "*" } } else { " " }
            $left = "$marker $($LocalItems[$li].Name)  $($LocalItems[$li].SizeLabel)"
        }
        if ($si -lt $ServerItems.Count) {
            $marker = if ($si -eq $ServerSelected) { if ($ActivePane -eq "server") { ">" } else { "*" } } else { " " }
            $right = "$marker $($ServerItems[$si].name)  $($ServerItems[$si].sizeLabel)"
        }
        Write-Host "|$(Fit-Text $left $inner)| |$(Fit-Text $right $inner)|"
    }

    Write-Host "$border $border"
    Write-Host "[Tab/Left/Right] Pane  [Up/Down or j/k] Select  [Enter] Open folder"
    Write-Host "[u] Upload selected  [d] Download selected  [x] Delete server file  [r] Refresh"
    Write-Host "[Esc/Ctrl+C] Cancel  [q] Quit"
    Write-Host -NoNewline (Fit-Text "Workers: $TransferWorkers  |  Status: $Status" ($width - 1))
}

function Read-KeyName {
    $key = [Console]::ReadKey($true)
    if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq [ConsoleKey]::C) { return "CANCEL" }
    switch ($key.Key) {
        "Escape" { return "CANCEL" }
        "Tab" { return "TAB" }
        "LeftArrow" { return "LEFT" }
        "RightArrow" { return "RIGHT" }
        "UpArrow" { return "UP" }
        "DownArrow" { return "DOWN" }
        "Enter" { return "ENTER" }
    }
    return $key.KeyChar.ToString().ToLowerInvariant()
}

function Confirm-Action([string]$Prompt) {
    $script:Status = "$Prompt [y/N, Esc cancels]"
    Show-Panes
    return (Read-KeyName) -eq "y"
}

function Wait-CancellableTask($Task, [Threading.CancellationTokenSource]$Cancellation) {
    while (-not $Task.IsCompleted) {
        if ([Console]::KeyAvailable) {
            $key = Read-KeyName
            if ($key -eq "CANCEL") {
                $Cancellation.Cancel()
                try { $Task.GetAwaiter().GetResult() | Out-Null } catch {}
                return $false
            }
        }
        Start-Sleep -Milliseconds 80
    }
    return $true
}

function Test-CancelRequested {
    if (-not [Console]::KeyAvailable) { return $false }
    return (Read-KeyName) -eq "CANCEL"
}

function Show-TransferProgress([string]$Action, [string]$Name, [long]$Transferred, [long]$Total, [int]$Workers, [DateTime]$Started) {
    $percent = if ($Total -gt 0) { [Math]::Min(100, [Math]::Floor($Transferred * 100 / $Total)) } else { 100 }
    $elapsed = [Math]::Max(1, ([DateTime]::UtcNow - $Started).TotalSeconds)
    $rate = [long]($Transferred / $elapsed)
    $barWidth = 24
    $filled = [int][Math]::Floor($percent * $barWidth / 100)
    $bar = ("#" * $filled) + ("-" * ($barWidth - $filled))
    $displayName = if ($Name.Length -gt 18) { $Name.Substring(0, 15) + "..." } else { $Name.PadRight(18) }
    $line = "{0,-8} {1} [{2}] {3,3}%  {4}/{5}  {6}/s  {7} workers  Esc/Ctrl+C cancels" -f $Action, $displayName, $bar, $percent, (Format-Size $Transferred), (Format-Size $Total), (Format-Size $rate), $Workers
    try { $width = [Math]::Max(64, [Console]::WindowWidth) } catch { $width = 80 }
    Write-Host -NoNewline ("`r" + (Fit-Text $line ($width - 1)))
}

function Dispose-ActiveTransfers($Active) {
    foreach ($record in @($Active)) {
        try { $record.Request.Dispose() } catch {}
        try { if ($record.Response) { $record.Response.Dispose() } } catch {}
    }
}

function Upload-Selected {
    if ($ActivePane -ne "local" -or $LocalSelected -lt 0 -or $LocalItems[$LocalSelected].IsDirectory) {
        $script:Status = "Select a file in the local pane to upload."
        return
    }
    $item = $LocalItems[$LocalSelected]
    if ($item.Name.StartsWith(".")) { $script:Status = "Server filenames cannot begin with a dot."; return }
    if (-not (Confirm-Action "Upload `"$($item.Name)`"?")) { $script:Status = "Upload cancelled."; return }
    $session = $null
    $active = [Collections.ArrayList]::new()
    $cancellation = [Threading.CancellationTokenSource]::new()
    $finished = $false
    try {
        $id = Get-FileId $item.Name
        $session = Invoke-RestMethod -Uri "$BaseUrl/api/cli/uploads/${id}?size=$($item.Length)&partSize=$TransferPartSize" -Headers $Headers -Method Post
        $workers = [Math]::Min($TransferWorkers, [int]$session.partCount)
        $nextPart = 0
        [long]$completedBytes = 0
        $started = [DateTime]::UtcNow
        $script:Status = "Parallel upload: $workers workers."
        Show-Panes
        while ($nextPart -lt $session.partCount -or $active.Count -gt 0) {
            while ($nextPart -lt $session.partCount -and $active.Count -lt $workers) {
                [long]$offset = $nextPart * [long]$session.partSize
                [int]$length = [int][Math]::Min([long]$session.partSize, [long]$item.Length - $offset)
                $buffer = New-Object byte[] $length
                $stream = [IO.File]::OpenRead($item.FullName)
                try {
                    [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
                    $read = 0
                    while ($read -lt $length) {
                        $count = $stream.Read($buffer, $read, $length - $read)
                        if ($count -eq 0) { throw "Unexpected end of local file" }
                        $read += $count
                    }
                } finally { $stream.Dispose() }
                $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Put, "$BaseUrl/api/cli/uploads/$($session.id)/parts/$nextPart")
                $request.Content = [Net.Http.ByteArrayContent]::new($buffer)
                $task = $Http.SendAsync($request, $cancellation.Token)
                [void]$active.Add([pscustomobject]@{ Task = $task; Request = $request; Response = $null; Length = $length; Index = $nextPart })
                $nextPart++
            }
            for ($index = $active.Count - 1; $index -ge 0; $index--) {
                $record = $active[$index]
                if (-not $record.Task.IsCompleted) { continue }
                $response = $record.Task.GetAwaiter().GetResult()
                $record.Response = $response
                $response.EnsureSuccessStatusCode() | Out-Null
                $completedBytes += $record.Length
                $response.Dispose(); $request = $record.Request; $request.Dispose()
                $active.RemoveAt($index)
            }
            Show-TransferProgress "UPLOAD" $item.Name $completedBytes $item.Length $workers $started
            if (Test-CancelRequested) { $cancellation.Cancel(); throw [OperationCanceledException]::new() }
            if ($active.Count -gt 0) { Start-Sleep -Milliseconds 80 }
        }
        Write-Host ""
        Invoke-RestMethod -Uri "$BaseUrl/api/cli/uploads/$($session.id)/finish" -Headers $Headers -Method Post | Out-Null
        $finished = $true
        $script:ServerItems = @(Get-ServerItems)
        Clamp-Selections
        $script:Status = "Uploaded $($item.Name) with $workers workers."
    } catch [OperationCanceledException] {
        Write-Host ""
        $script:Status = "Upload cancelled."
    } catch {
        Write-Host ""
        $script:Status = "Parallel upload failed: $($_.Exception.Message)"
    } finally {
        if (-not $cancellation.IsCancellationRequested) { $cancellation.Cancel() }
        Dispose-ActiveTransfers $active
        if ($session -and -not $finished) {
            try { Invoke-RestMethod -Uri "$BaseUrl/api/cli/uploads/$($session.id)" -Headers $Headers -Method Delete | Out-Null } catch {}
        }
        $cancellation.Dispose()
    }
}

function Download-Selected {
    if ($ActivePane -ne "server" -or $ServerSelected -lt 0) {
        $script:Status = "Select a file in the server pane to download."
        return
    }
    $item = $ServerItems[$ServerSelected]
    $destination = Join-Path $LocalDirectory $item.name
    $prompt = if (Test-Path -LiteralPath $destination) { "Replace local `"$($item.name)`"?" } else { "Download `"$($item.name)`" here?" }
    if (-not (Confirm-Action $prompt)) { $script:Status = "Download cancelled."; return }
    $partial = "$destination.tunnelpane-part.$PID"
    $stateDirectory = Join-Path ([IO.Path]::GetTempPath()) ("tunnelpane-download-" + [Guid]::NewGuid().ToString("N"))
    [void][IO.Directory]::CreateDirectory($stateDirectory)
    $active = [Collections.ArrayList]::new()
    $cancellation = [Threading.CancellationTokenSource]::new()
    try {
        [long]$total = $item.size
        if ($total -eq 0) {
            [IO.File]::WriteAllBytes($partial, (New-Object byte[] 0))
            Move-Item -LiteralPath $partial -Destination $destination -Force
            $script:LocalItems = @(Get-LocalItems); Clamp-Selections
            $script:Status = "Downloaded empty file $($item.name)."
            return
        }
        $partCount = [int][Math]::Ceiling($total / $TransferPartSize)
        $workers = [Math]::Min($TransferWorkers, $partCount)
        $nextPart = 0
        [long]$completedBytes = 0
        $started = [DateTime]::UtcNow
        $script:Status = "Parallel download: $workers workers."
        Show-Panes
        while ($nextPart -lt $partCount -or $active.Count -gt 0) {
            while ($nextPart -lt $partCount -and $active.Count -lt $workers) {
                [long]$start = $nextPart * [long]$TransferPartSize
                [long]$end = [Math]::Min($total - 1, $start + $TransferPartSize - 1)
                $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, "$BaseUrl/api/cli/files/$($item.id)")
                $request.Headers.Range = [Net.Http.Headers.RangeHeaderValue]::Parse("bytes=$start-$end")
                $task = $Http.SendAsync($request, $cancellation.Token)
                [void]$active.Add([pscustomobject]@{ Task = $task; Request = $request; Response = $null; Length = [int]($end - $start + 1); Index = $nextPart })
                $nextPart++
            }
            for ($index = $active.Count - 1; $index -ge 0; $index--) {
                $record = $active[$index]
                if (-not $record.Task.IsCompleted) { continue }
                $response = $record.Task.GetAwaiter().GetResult()
                $record.Response = $response
                $response.EnsureSuccessStatusCode() | Out-Null
                $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                if ($bytes.Length -ne $record.Length) { throw "Downloaded part has an invalid size" }
                [IO.File]::WriteAllBytes((Join-Path $stateDirectory "part.$($record.Index)"), $bytes)
                $completedBytes += $bytes.Length
                $response.Dispose(); $request = $record.Request; $request.Dispose()
                $active.RemoveAt($index)
            }
            Show-TransferProgress "DOWNLOAD" $item.name $completedBytes $total $workers $started
            if (Test-CancelRequested) { $cancellation.Cancel(); throw [OperationCanceledException]::new() }
            if ($active.Count -gt 0) { Start-Sleep -Milliseconds 80 }
        }
        Write-Host ""
        $output = [IO.File]::Open($partial, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            for ($part = 0; $part -lt $partCount; $part++) {
                $input = [IO.File]::OpenRead((Join-Path $stateDirectory "part.$part"))
                try { $input.CopyTo($output) } finally { $input.Dispose() }
            }
        } finally { $output.Dispose() }
        if ((Get-Item -LiteralPath $partial).Length -ne $total) { throw "Download verification failed" }
        Move-Item -LiteralPath $partial -Destination $destination -Force
        $script:LocalItems = @(Get-LocalItems)
        Clamp-Selections
        $script:Status = "Downloaded $($item.name) with $workers workers."
    } catch [OperationCanceledException] {
        Write-Host ""
        $script:Status = "Download cancelled."
    } catch {
        Write-Host ""
        $script:Status = "Parallel download failed: $($_.Exception.Message)"
    } finally {
        if (-not $cancellation.IsCancellationRequested) { $cancellation.Cancel() }
        Dispose-ActiveTransfers $active
        $cancellation.Dispose()
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
        if (Test-Path -LiteralPath $stateDirectory) { Remove-Item -LiteralPath $stateDirectory -Recurse -Force }
    }
}

function Delete-Selected {
    if ($ActivePane -ne "server" -or $ServerSelected -lt 0) {
        $script:Status = "Select a file in the server pane to delete."
        return
    }
    $item = $ServerItems[$ServerSelected]
    if (-not (Confirm-Action "Delete `"$($item.name)`" from the server?")) { $script:Status = "Delete cancelled."; return }
    $cancellation = [Threading.CancellationTokenSource]::new()
    try {
        $script:Status = "Deleting $($item.name) - Esc or Ctrl+C cancels."
        Show-Panes
        $task = $Http.DeleteAsync("$BaseUrl/api/cli/files/$($item.id)", $cancellation.Token)
        if (-not (Wait-CancellableTask $task $cancellation)) { $script:Status = "Delete cancelled."; return }
        $response = $task.GetAwaiter().GetResult()
        $response.EnsureSuccessStatusCode() | Out-Null
        $response.Dispose()
        $script:ServerItems = @(Get-ServerItems)
        Clamp-Selections
        $script:Status = "Deleted $($item.name)."
    } catch [OperationCanceledException] {
        $script:Status = "Delete cancelled."
    } catch {
        $script:Status = "Delete failed: $($_.Exception.Message)"
    } finally {
        $cancellation.Dispose()
    }
}

$Username = Read-Host "Username"
if ([string]::IsNullOrWhiteSpace($Username)) {
    Write-Host "Username is required." -ForegroundColor Red
    exit 1
}
$SecurePassword = Read-Host "Password" -AsSecureString
$Password = [Net.NetworkCredential]::new("", $SecurePassword).Password
$Token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${Username}:${Password}"))
$Headers = @{ Authorization = "Basic $Token" }

try {
    Add-Type -AssemblyName System.Net.Http
    $Http = [Net.Http.HttpClient]::new()
    $Http.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new("Basic", $Token)
    $LocalItems = @(Get-LocalItems)
    $ServerItems = @(Get-ServerItems)
    Clamp-Selections
} catch {
    Write-Host "Authentication failed or the service is unavailable." -ForegroundColor Red
    exit 1
}

$oldControlC = [Console]::TreatControlCAsInput
[Console]::TreatControlCAsInput = $true
try {
    while ($true) {
        Show-Panes
        $command = Read-KeyName
        switch ($command) {
            { $_ -in @("TAB", "LEFT", "RIGHT") } {
                $ActivePane = if ($ActivePane -eq "local") { "server" } else { "local" }
                $Status = "Active pane: $($ActivePane.ToUpperInvariant())."
            }
            { $_ -in @("UP", "k") } {
                if ($ActivePane -eq "local" -and $LocalSelected -gt 0) { $LocalSelected-- }
                elseif ($ActivePane -eq "server" -and $ServerSelected -gt 0) { $ServerSelected-- }
            }
            { $_ -in @("DOWN", "j") } {
                if ($ActivePane -eq "local" -and $LocalSelected -lt $LocalItems.Count - 1) { $LocalSelected++ }
                elseif ($ActivePane -eq "server" -and $ServerSelected -lt $ServerItems.Count - 1) { $ServerSelected++ }
            }
            "ENTER" {
                if ($ActivePane -eq "local" -and $LocalSelected -ge 0 -and $LocalItems[$LocalSelected].IsDirectory) {
                    $LocalDirectory = $LocalItems[$LocalSelected].FullName
                    $LocalSelected = 0; $LocalOffset = 0
                    $LocalItems = @(Get-LocalItems)
                    Clamp-Selections
                    $Status = "Opened $LocalDirectory."
                } else { $Status = "Enter opens folders in the local pane." }
            }
            "u" { Upload-Selected }
            "d" { Download-Selected }
            "x" { Delete-Selected }
            "r" {
                $LocalItems = @(Get-LocalItems)
                try { $ServerItems = @(Get-ServerItems); $Status = "Both panes refreshed." }
                catch { $Status = "Server refresh failed." }
                Clamp-Selections
            }
            "CANCEL" { $Status = "Cancelled." }
            "q" { break }
        }
        if ($command -eq "q") { break }
    }
} finally {
    [Console]::TreatControlCAsInput = $oldControlC
    if ($Http) { $Http.Dispose() }
    $Password = $null
    $Token = $null
    $Headers = $null
    $SecurePassword = $null
}

Clear-Host
Write-Host "Signed out of TunnelPane."
