$ErrorActionPreference = "Stop"
$BaseUrl = if ($env:TUNNELPANE_URL) { $env:TUNNELPANE_URL.TrimEnd("/") } else { "__TUNNELPANE_URL__" }
$LocalDirectory = (Get-Location).Path
$ServerDirectory = ""
$ActivePane = "local"
$LocalSelected = 0
$ServerSelected = 0
$LocalOffset = 0
$ServerOffset = 0
$Status = "Ready."
$TransferWorkers = if ($env:TUNNELPANE_TRANSFERS) { [int]$env:TUNNELPANE_TRANSFERS } else { 4 }
if ($TransferWorkers -lt 1) { $TransferWorkers = 4 }
if ($TransferWorkers -gt 8) { $TransferWorkers = 8 }
$TransferPartSize = 16MB

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
    $uri = "$BaseUrl/api/cli/files?format=json3"
    if ($ServerDirectory) { $uri += "&path=$(Get-FileId $ServerDirectory)" }
    $result = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get
    $items = @()
    if ($ServerDirectory) { $items += [pscustomobject]@{ id = ".."; name = ".."; type = "parent"; size = 0; sizeLabel = "-"; modified = "" } }
    $items += @($result.files)
    return @($items)
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

function New-TitleBorder([string]$Title, [int]$Width) {
    $label = "+-- $Title "
    return $label + ("-" * [Math]::Max(0, $Width - $label.Length - 1)) + "+"
}

function New-ItemRow([string]$Name, [string]$Size, [string]$Modified, [int]$Width, [string]$Marker, [bool]$ShowDate) {
    if ($ShowDate) {
        $nameWidth = [Math]::Max(8, $Width - 31)
        $display = Fit-Text $Name $nameWidth
        $value = "{0} {1} {2,9}  {3,-16} " -f $Marker, $display, $Size, $Modified
    } else {
        $nameWidth = [Math]::Max(8, $Width - 14)
        $display = Fit-Text $Name $nameWidth
        $value = "{0} {1} {2,9} " -f $Marker, $display, $Size
    }
    return Fit-Text $value $Width
}

function Write-Key([string]$Key) {
    Write-Host -NoNewline ($Key.PadRight(5)) -ForegroundColor Cyan
}

function Write-PaneRow([string]$Row, [bool]$Selected, [bool]$Active, [bool]$Directory, [ConsoleColor]$Accent) {
    Write-Host -NoNewline "|" -ForegroundColor $Accent
    if ($Selected -and $Active) {
        $background = if ($Accent -eq [ConsoleColor]::Cyan) { [ConsoleColor]::Cyan } else { [ConsoleColor]::Yellow }
        Write-Host -NoNewline $Row -ForegroundColor Black -BackgroundColor $background
    } elseif ($Selected) {
        Write-Host -NoNewline $Row -ForegroundColor White
    } elseif ($Directory) {
        Write-Host -NoNewline $Row -ForegroundColor Cyan
    } else {
        Write-Host -NoNewline $Row
    }
    Write-Host -NoNewline "|" -ForegroundColor $Accent
}

function Show-Panes {
    try { $width = [Console]::WindowWidth - 1; $height = [Console]::WindowHeight }
    catch { $width = 80; $height = 24 }
    if ($width -lt 72 -or $height -lt 16) {
        [Console]::Clear()
        Write-Host "TunnelPane needs at least 72 columns and 16 rows." -ForegroundColor Yellow
        return
    }
    $gap = 2
    $paneWidth = [Math]::Floor(($width - $gap) / 2)
    $inner = $paneWidth - 2
    $rows = [Math]::Max(6, $height - 9)
    $showDate = $inner -ge 48
    Adjust-Offsets $rows

    [Console]::SetCursorPosition(0, 0)
    $rightHeader = "HTTPS  |  $TransferWorkers PARALLEL WORKERS "
    Write-Host -NoNewline " TUNNELPANE" -ForegroundColor Cyan
    Write-Host -NoNewline (" " * [Math]::Max(1, $width - 11 - $rightHeader.Length))
    Write-Host $rightHeader -ForegroundColor DarkGray
    Write-Host (Fit-Text " LOCAL PATH  $LocalDirectory" $width) -ForegroundColor DarkGray

    $localAccent = if ($ActivePane -eq "local") { [ConsoleColor]::Cyan } else { [ConsoleColor]::DarkGray }
    $serverAccent = if ($ActivePane -eq "server") { [ConsoleColor]::Yellow } else { [ConsoleColor]::DarkGray }
    Write-Host -NoNewline (New-TitleBorder "LOCAL  $($LocalItems.Count) items" $paneWidth) -ForegroundColor $localAccent
    Write-Host -NoNewline "  "
    $serverTitle = if ($ServerDirectory) { $ServerDirectory } else { "/" }
    Write-Host (New-TitleBorder "SERVER  $serverTitle" $paneWidth) -ForegroundColor $serverAccent

    $leftHeader = New-ItemRow "NAME" "SIZE" "" $inner " " $false
    $rightHeaderRow = New-ItemRow "NAME" "SIZE" "MODIFIED" $inner " " $showDate
    Write-PaneRow $leftHeader $false $false $false ([ConsoleColor]::DarkGray)
    Write-Host -NoNewline "  "
    Write-PaneRow $rightHeaderRow $false $false $false ([ConsoleColor]::DarkGray)
    Write-Host
    $separator = "-" * $inner
    Write-Host "|$separator|  |$separator|" -ForegroundColor DarkGray

    for ($row = 0; $row -lt $rows; $row++) {
        $li = $LocalOffset + $row
        $si = $ServerOffset + $row
        $left = Fit-Text "" $inner
        $right = Fit-Text "" $inner
        $leftSelected = $false
        $rightSelected = $false
        $isDirectory = $false
        if ($li -lt $LocalItems.Count) {
            $marker = if ($li -eq $LocalSelected) { if ($ActivePane -eq "local") { ">" } else { "*" } } else { " " }
            $leftSelected = $li -eq $LocalSelected
            $isDirectory = $LocalItems[$li].IsDirectory
            $left = New-ItemRow $LocalItems[$li].Name $LocalItems[$li].SizeLabel "" $inner $marker $false
        }
        if ($si -lt $ServerItems.Count) {
            $marker = if ($si -eq $ServerSelected) { if ($ActivePane -eq "server") { ">" } else { "*" } } else { " " }
            $rightSelected = $si -eq $ServerSelected
            $modified = if ($showDate) { ([string]$ServerItems[$si].modified).Replace("T", " ").Substring(0, [Math]::Min(16, ([string]$ServerItems[$si].modified).Length)) } else { "" }
            $serverName = if ($ServerItems[$si].type -eq "dir") { $ServerItems[$si].name + "/" } else { $ServerItems[$si].name }
            $right = New-ItemRow $serverName $ServerItems[$si].sizeLabel $modified $inner $marker $showDate
        } elseif ($ServerItems.Count -eq 0 -and $row -eq 0) {
            $right = Fit-Text "  No files on server" $inner
        }
        Write-PaneRow $left $leftSelected ($ActivePane -eq "local") $isDirectory $localAccent
        Write-Host -NoNewline "  "
        Write-PaneRow $right $rightSelected ($ActivePane -eq "server") ($si -lt $ServerItems.Count -and $ServerItems[$si].type -eq "dir") $serverAccent
        Write-Host
    }

    $bottom = "+-" + ("-" * ($paneWidth - 4)) + "-+"
    Write-Host "$bottom  $bottom" -ForegroundColor DarkGray
    Write-Key "TAB"; Write-Host -NoNewline " pane   "; Write-Key "J/K"; Write-Host -NoNewline " move   "; Write-Key "ENTER"; Write-Host -NoNewline " open   "; Write-Key "U"; Write-Host -NoNewline " upload   "; Write-Key "D"; Write-Host " download"
    Write-Key "M"; Write-Host -NoNewline " mkdir   "; Write-Key "X"; Write-Host -NoNewline " delete  "; Write-Key "R"; Write-Host -NoNewline " refresh "; Write-Key "ESC"; Write-Host -NoNewline " cancel  "; Write-Key "Q"; Write-Host " quit"

    $statusColor = [ConsoleColor]::Cyan
    $statusLabel = " READY "
    if ($Status -match "fail|error|cannot") { $statusColor = [ConsoleColor]::Red; $statusLabel = " ERROR " }
    elseif ($Status -match "cancelled") { $statusColor = [ConsoleColor]::Yellow; $statusLabel = " PAUSED " }
    elseif ($Status -match "\[y/N") { $statusColor = [ConsoleColor]::Yellow; $statusLabel = " ACTION " }
    elseif ($Status -match "^(Uploaded|Downloaded|Deleted)") { $statusColor = [ConsoleColor]::Green; $statusLabel = " DONE  " }
    Write-Host -NoNewline $statusLabel -ForegroundColor Black -BackgroundColor $statusColor
    Write-Host -NoNewline (Fit-Text " $Status" ($width - $statusLabel.Length))
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
    try { $width = [Console]::WindowWidth - 1 } catch { $width = 79 }
    $nameWidth = if ($width -gt 110) { 24 } else { 14 }
    $displayName = Fit-Text $Name $nameWidth
    if ($width -lt 96) {
        $details = "{0,3}%  {1}/{2}  ESC CANCEL" -f $percent, (Format-Size $Transferred), (Format-Size $Total)
    } else {
        $details = "{0,3}%  {1}/{2}  {3}/s  {4}W  ESC CANCEL" -f $percent, (Format-Size $Transferred), (Format-Size $Total), (Format-Size $rate), $Workers
    }
    $barWidth = [Math]::Max(10, [Math]::Min(32, $width - $Action.Length - $nameWidth - $details.Length - 13))
    $filled = [int][Math]::Floor($percent * $barWidth / 100)
    Write-Host -NoNewline "`r"
    Write-Host -NoNewline (" {0,-8}" -f $Action) -ForegroundColor Cyan
    Write-Host -NoNewline " $displayName  ["
    Write-Host -NoNewline ("#" * $filled) -ForegroundColor Green
    Write-Host -NoNewline ("-" * ($barWidth - $filled)) -ForegroundColor DarkGray
    $tail = "]  $details"
    Write-Host -NoNewline (Fit-Text $tail ($width - 13 - $nameWidth - $barWidth))
}

function Dispose-ActiveTransfers($Active) {
    foreach ($record in @($Active)) {
        try { $record.Request.Dispose() } catch {}
        try { if ($record.Response) { $record.Response.Dispose() } } catch {}
    }
}

function New-ServerFolder([string]$Path) {
    $id = Get-FileId $Path
    Invoke-RestMethod -Uri "$BaseUrl/api/cli/folders/$id" -Headers $Headers -Method Post | Out-Null
}

function Upload-File($item, [string]$TargetPath) {
    $session = $null
    $active = [Collections.ArrayList]::new()
    $cancellation = [Threading.CancellationTokenSource]::new()
    $finished = $false
    try {
        $id = Get-FileId $TargetPath
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

function Upload-Selected {
    if ($ActivePane -ne "local" -or $LocalSelected -lt 0) {
        $script:Status = "Select a local file or folder to upload."
        return
    }
    $item = $LocalItems[$LocalSelected]
    $name = $item.Name.TrimEnd("/")
    if ($name.StartsWith(".")) { $script:Status = "Hidden items cannot be uploaded."; return }
    $target = if ($ServerDirectory) { "$ServerDirectory/$name" } else { $name }
    if (-not $item.IsDirectory) {
        if (-not (Confirm-Action "Upload `"$name`"?")) { $script:Status = "Upload cancelled."; return }
        Upload-File $item $target
        return
    }

    if ($name -eq "..") { $script:Status = "Select a folder, not its parent entry."; return }
    if (-not (Confirm-Action "Upload folder `"$name`" recursively?")) { $script:Status = "Upload cancelled."; return }
    try {
        New-ServerFolder $target
        $directories = @(Get-ChildItem -LiteralPath $item.FullName -Directory -Recurse -Force | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::Hidden) })
        foreach ($directory in $directories) {
            $relative = $directory.FullName.Substring($item.FullName.Length).TrimStart("\", "/").Replace("\", "/")
            if ($relative.Split("/") | Where-Object { $_.StartsWith(".") }) { continue }
            New-ServerFolder "$target/$relative"
        }
        $files = @(Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Force | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::Hidden) })
        $count = 0
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($item.FullName.Length).TrimStart("\", "/").Replace("\", "/")
            if ($relative.Split("/") | Where-Object { $_.StartsWith(".") }) { continue }
            $count++
            $uploadItem = [pscustomobject]@{ Name = $relative; FullName = $file.FullName; Length = [long]$file.Length }
            $script:Status = "Folder upload $count/$($files.Count): $relative"
            Upload-File $uploadItem "$target/$relative"
            if ($Status -match "cancelled|failed") { return }
        }
        $script:ServerItems = @(Get-ServerItems); Clamp-Selections
        $script:Status = "Uploaded folder $name ($count files)."
    } catch {
        $script:Status = "Folder upload failed: $($_.Exception.Message)"
    }
}

function New-Folder {
    $script:Status = "Create folder in $($ActivePane.ToUpperInvariant())."
    Show-Panes
    try { [Console]::CursorVisible = $true } catch {}
    $name = Read-Host " Folder name"
    try { [Console]::CursorVisible = $false } catch {}
    if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith(".") -or $name.Contains("/") -or $name.Contains("\") -or $name -in @(".", "..")) {
        $script:Status = "Folder name is invalid."
        return
    }
    try {
        if ($ActivePane -eq "local") {
            New-Item -ItemType Directory -Path (Join-Path $LocalDirectory $name) -ErrorAction Stop | Out-Null
            $script:LocalItems = @(Get-LocalItems)
            $script:Status = "Created local folder $name."
        } else {
            $target = if ($ServerDirectory) { "$ServerDirectory/$name" } else { $name }
            New-ServerFolder $target
            $script:ServerItems = @(Get-ServerItems)
            $script:Status = "Created server folder $name."
        }
        Clamp-Selections
    } catch { $script:Status = "Could not create folder: $($_.Exception.Message)" }
}

function Download-Selected {
    if ($ActivePane -ne "server" -or $ServerSelected -lt 0 -or $ServerItems[$ServerSelected].type -ne "file") {
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
    if ($ActivePane -ne "server" -or $ServerSelected -lt 0 -or $ServerItems[$ServerSelected].type -eq "parent") {
        $script:Status = "Select a file or folder in the server pane to delete."
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
try { $oldCursorVisible = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch { $oldCursorVisible = $true }
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
                } elseif ($ActivePane -eq "server" -and $ServerSelected -ge 0 -and $ServerItems[$ServerSelected].type -eq "parent") {
                    $ServerDirectory = if ($ServerDirectory.Contains("/")) { $ServerDirectory.Substring(0, $ServerDirectory.LastIndexOf("/")) } else { "" }
                    $ServerSelected = 0; $ServerOffset = 0
                    $ServerItems = @(Get-ServerItems); Clamp-Selections
                    $Status = "Opened server /$ServerDirectory."
                } elseif ($ActivePane -eq "server" -and $ServerSelected -ge 0 -and $ServerItems[$ServerSelected].type -eq "dir") {
                    $ServerDirectory = if ($ServerDirectory) { "$ServerDirectory/$($ServerItems[$ServerSelected].name)" } else { $ServerItems[$ServerSelected].name }
                    $ServerSelected = 0; $ServerOffset = 0
                    $ServerItems = @(Get-ServerItems); Clamp-Selections
                    $Status = "Opened server /$ServerDirectory."
                } else { $Status = "Enter opens the selected folder." }
            }
            "u" { Upload-Selected }
            "d" { Download-Selected }
            "m" { New-Folder }
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
    try { [Console]::CursorVisible = $oldCursorVisible } catch {}
    if ($Http) { $Http.Dispose() }
    $Password = $null
    $Token = $null
    $Headers = $null
    $SecurePassword = $null
}

Clear-Host
Write-Host "Signed out of TunnelPane."
