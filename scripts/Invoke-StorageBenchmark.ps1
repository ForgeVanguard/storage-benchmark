#Requires -Version 5.1
<#
.SYNOPSIS
    Storage throughput and latency benchmark for Windows file servers and workstations.

.DESCRIPTION
    Creates test files (1, 2 and 10 GB by default) on a source volume, then measures:

      * Write  : source -> each target path
      * Read   : each target path -> a read-back folder on the source volume

    Copies use Robocopy unbuffered I/O (/J) so the file system cache does not inflate
    results. For every transfer the script records the Robocopy exit code, duration,
    MB/s, and LogicalDisk latency (Avg. Disk sec/Read and Avg. Disk sec/Write) for every
    local drive involved, sampled before and after the copy.

    Targets can be local folders on other volumes or UNC paths (SMB shares, NAS, SAN
    LUNs presented as drives). Latency counters are only collected for local drive
    letters.

    Results are written to CSV: one detail row per transfer, plus averages per file
    size, per destination, read vs write, and overall.

    Typical use: working out whether slow file opens, saves, or media transfers on a
    server are a storage problem, and which leg (write or read-back) is the slow one.

.PARAMETER SourcePath
    Folder on the source volume where the test files are created.

.PARAMETER TargetPath
    One or more destination folders (local or UNC) to write the test files to.

.PARAMETER ReadBackRoot
    Folder on the source volume that read-back copies land in. One sub-folder is
    created per target. Defaults to <SourcePath>\..\ReadBack.

.PARAMETER FileSizesGB
    Test file sizes in GB. Default 1, 2, 10.

.PARAMETER ReportRoot
    Folder for the log and CSV reports.

.PARAMETER Cleanup
    Delete the test files and read-back copies when the run finishes.

.NOTES
    Author : Steven Drew
    License: MIT
    Works in Windows PowerShell 5.1 (including the ISE) and PowerShell 7. Run elevated
    so the disk counters and large unbuffered copies are less likely to fail.

    Free space needed: the total of FileSizesGB on each target, and (1 + number of
    targets) x that total on the source volume.

    Robocopy exit codes 0-7 are success/informational bit flags; 8 and above are
    treated as failures. A copy that reports success but leaves a destination file
    of the wrong size is also marked failed.

    Test files are created with fsutil (zero-filled). Storage that compresses or
    deduplicates zeros inline will report optimistic numbers.

    Exit codes: 0 all transfers succeeded, 1 setup error, 2 one or more transfers failed.

.EXAMPLE
    .\Invoke-StorageBenchmark.ps1 -SourcePath 'D:\Bench' -TargetPath 'E:\Bench','\\<HOSTNAME>\share\Bench'

.EXAMPLE
    .\Invoke-StorageBenchmark.ps1 -SourcePath 'D:\Bench' -TargetPath 'E:\Bench' -FileSizesGB 1,4 -Cleanup
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string[]]$TargetPath,

    [string]$ReadBackRoot,

    [ValidateRange(1, 1024)]
    [int[]]$FileSizesGB = @(1, 2, 10),

    [string]$ReportRoot = (Join-Path $env:SystemDrive 'Temp\StorageBenchmark'),

    [int]$RobocopyRetries = 3,
    [int]$RobocopyWaitSec = 5,

    [switch]$Cleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
$script:ComputerName = $env:COMPUTERNAME
$script:RunId        = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:BytesPerMB   = 1MB   # 1048576; throughput labeled MB/s using binary MB
$script:LogPath      = $null
$script:Retries      = $RobocopyRetries
$script:WaitSec      = $RobocopyWaitSec
$script:CounterCache = @{}   # drive letter -> valid LogicalDisk instance name

$TestFileSpecs = @(foreach ($gb in ($FileSizesGB | Sort-Object -Unique)) {
    @{ Name = ('TestFile_{0}GB.bin' -f $gb); SizeBytes = [int64]$gb * 1GB }
})

if ([string]::IsNullOrWhiteSpace($ReadBackRoot)) {
    $ReadBackRoot = Join-Path (Split-Path -Parent $SourcePath.TrimEnd('\')) 'ReadBack'
}

function Get-LocalDriveLetter {
    param([string]$Path)
    if ($Path -match '^([A-Za-z]):') { return $Matches[1].ToUpperInvariant() }
    return $null
}

# Local drive letters involved in the test; latency counters are sampled for these.
$TrackedDrives = @(
    @($SourcePath) + @($TargetPath) | ForEach-Object { Get-LocalDriveLetter -Path $_ } |
        Where-Object { $_ } | Select-Object -Unique
)

# One write job and one read-back job per target.
$Targets = @(for ($i = 0; $i -lt $TargetPath.Count; $i++) {
    $label = ('T{0}' -f ($i + 1))
    @{
        Label    = $label
        Path     = $TargetPath[$i]
        ReadBack = Join-Path $ReadBackRoot $label
    }
})

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
function Write-BenchLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')]
        [string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($script:LogPath) {
        try {
            Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
        }
        catch {
            # Logging must not abort a running test.
            $null = $_
        }
    }
}

# -----------------------------------------------------------------------------
# Environment helpers
# -----------------------------------------------------------------------------
function Test-DriveReady {
    param([Parameter(Mandatory = $true)][string]$DriveLetter)

    $letter = $DriveLetter.TrimEnd(':').Substring(0, 1).ToUpperInvariant()
    $drivePath = $letter + ':\'

    if (-not (Test-Path -LiteralPath $drivePath)) {
        return $false
    }

    try {
        $psDrive = Get-PSDrive -Name $letter -PSProvider FileSystem -ErrorAction Stop
        if ($null -eq $psDrive) { return $false }
        return $true
    }
    catch {
        return $false
    }
}

function Get-DriveFreeSpace {
    param([Parameter(Mandatory = $true)][string]$DriveLetter)

    $letter = $DriveLetter.TrimEnd(':').Substring(0, 1).ToUpperInvariant()
    try {
        $wmi = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$letter`:'" -ErrorAction Stop
        if ($null -eq $wmi) { return [int64]0 }
        return [int64]$wmi.FreeSpace
    }
    catch {
        try {
            $drive = Get-PSDrive -Name $letter -PSProvider FileSystem -ErrorAction Stop
            return [int64]$drive.Free
        }
        catch {
            return [int64]0
        }
    }
}

function Initialize-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Directory path is empty."
    }

    $root = [System.IO.Path]::GetPathRoot($Path)
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) {
        throw "Drive or root path does not exist: $root (requested $Path)"
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
        Write-BenchLog "Created directory $Path"
    }
}

# -----------------------------------------------------------------------------
# Test file creation
# -----------------------------------------------------------------------------
function Initialize-BenchmarkFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int64]$SizeBytes
    )

    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($existing.Length -eq $SizeBytes) {
            Write-BenchLog "Reusing existing test file $($existing.Name) ($([math]::Round($SizeBytes / 1GB, 2)) GB)"
            return
        }
        Write-BenchLog "Existing file size mismatch for $Path; recreating." 'WARN'
        Remove-Item -LiteralPath $Path -Force
    }

    Write-BenchLog "Creating $Path ($([math]::Round($SizeBytes / 1GB, 2)) GB)..."

    # fsutil createnew is fast and available on Windows Server. Fall back to
    # a FileStream SetLength allocation if fsutil is unavailable.
    $created = $false
    $fsutil = Get-Command fsutil.exe -ErrorAction SilentlyContinue
    if ($fsutil) {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $output = & fsutil.exe file createnew $Path $SizeBytes 2>&1
        $fsutilExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEap

        if ($fsutilExit -eq 0 -and (Test-Path -LiteralPath $Path)) {
            $actual = (Get-Item -LiteralPath $Path).Length
            if ($actual -eq $SizeBytes) {
                $created = $true
            }
        }

        if (-not $created) {
            Write-BenchLog "fsutil createnew did not produce the expected file. Output: $output" 'WARN'
            if (Test-Path -LiteralPath $Path) {
                Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $created) {
        $stream = $null
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $stream.SetLength($SizeBytes)
            $created = $true
        }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }

    if (-not $created -or -not (Test-Path -LiteralPath $Path) -or ((Get-Item -LiteralPath $Path).Length -ne $SizeBytes)) {
        throw "Failed to create test file $Path at $SizeBytes bytes."
    }

    Write-BenchLog "Created $Path" 'OK'
}

# -----------------------------------------------------------------------------
# Performance counters
# -----------------------------------------------------------------------------
function Resolve-LogicalDiskInstance {
    param([Parameter(Mandatory = $true)][string]$DriveLetter)

    $letter = $DriveLetter.TrimEnd(':').Substring(0, 1).ToUpperInvariant()
    if ($script:CounterCache.ContainsKey($letter)) {
        return $script:CounterCache[$letter]
    }

    $candidates = @(
        "$letter`:",
        $letter,
        "$letter`:\ "
    )

    $instance = $null
    try {
        $set = Get-Counter -ListSet LogicalDisk -ErrorAction Stop
        $names = @($set.PathsWithInstances | ForEach-Object {
            if ($_ -match '\\LogicalDisk\(([^)]+)\)\\') { $Matches[1] }
        } | Select-Object -Unique)

        foreach ($c in $candidates) {
            $trimmed = $c.Trim()
            if ($names -contains $trimmed) {
                $instance = $trimmed
                break
            }
        }

        if ($null -eq $instance) {
            foreach ($n in $names) {
                if ($n -like "$letter*") {
                    $instance = $n
                    break
                }
            }
        }
    }
    catch {
        Write-BenchLog "Could not list LogicalDisk counter instances: $($_.Exception.Message)" 'WARN'
    }

    $script:CounterCache[$letter] = $instance
    if ($null -eq $instance) {
        Write-BenchLog "No LogicalDisk counter instance found for ${letter}:" 'WARN'
    }
    else {
        Write-BenchLog "Mapped drive ${letter}: to counter instance '$instance'"
    }
    return $instance
}

function Get-DiskLatencySnapshot {
    <#
        Returns a hashtable with <Drive>_AvgReadMs and <Drive>_AvgWriteMs for each
        tracked drive. Values are milliseconds. Missing or failed counters are $null.
    #>
    $result = @{}
    foreach ($d in $TrackedDrives) {
        $result["${d}_AvgReadMs"]  = $null
        $result["${d}_AvgWriteMs"] = $null
    }

    $paths = New-Object System.Collections.Generic.List[string]
    $map   = @{}  # counter path -> @{ Drive = 'D'; Kind = 'Read' }

    foreach ($d in $TrackedDrives) {
        $instance = Resolve-LogicalDiskInstance -DriveLetter $d
        if ([string]::IsNullOrWhiteSpace($instance)) { continue }

        $readPath  = "\LogicalDisk($instance)\Avg. Disk sec/Read"
        $writePath = "\LogicalDisk($instance)\Avg. Disk sec/Write"
        $paths.Add($readPath)  | Out-Null
        $paths.Add($writePath) | Out-Null
        $map[$readPath.ToLowerInvariant()]  = @{ Drive = $d; Kind = 'Read' }
        $map[$writePath.ToLowerInvariant()] = @{ Drive = $d; Kind = 'Write' }
    }

    if ($paths.Count -eq 0) {
        Write-BenchLog "No disk latency counters available for this snapshot." 'WARN'
        return $result
    }

    try {
        $counterData = Get-Counter -Counter $paths.ToArray() -SampleInterval 1 -MaxSamples 1 -ErrorAction SilentlyContinue
        if ($null -eq $counterData -or $null -eq $counterData.CounterSamples) {
            Write-BenchLog "Get-Counter returned no samples for this snapshot." 'WARN'
            return $result
        }
        foreach ($sample in $counterData.CounterSamples) {
            $key = $sample.Path.ToLowerInvariant()
            # Get-Counter paths are often \\machine\logicaldisk(f:)\avg. disk sec/read
            $matched = $null
            foreach ($p in $map.Keys) {
                if ($key.EndsWith($p.ToLowerInvariant()) -or $key.Contains($p.ToLowerInvariant().TrimStart('\'))) {
                    $matched = $map[$p]
                    break
                }
            }
            if ($null -eq $matched) { continue }

            $ms = $null
            if ($null -ne $sample.CookedValue -and -not [double]::IsNaN($sample.CookedValue) -and -not [double]::IsInfinity($sample.CookedValue)) {
                $ms = [math]::Round(([double]$sample.CookedValue * 1000.0), 4)
            }

            if ($matched.Kind -eq 'Read') {
                $result["$($matched.Drive)_AvgReadMs"] = $ms
            }
            else {
                $result["$($matched.Drive)_AvgWriteMs"] = $ms
            }
        }
    }
    catch {
        Write-BenchLog "Performance counter collection failed: $($_.Exception.Message)" 'WARN'
    }

    return $result
}

# -----------------------------------------------------------------------------
# Robocopy transfer
# -----------------------------------------------------------------------------
function Invoke-RobocopyFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$DestDir,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $robocopy = Get-Command robocopy.exe -ErrorAction SilentlyContinue
    if (-not $robocopy) {
        throw "robocopy.exe was not found on PATH."
    }

    $sourceFile = Join-Path $SourceDir $FileName
    if (-not (Test-Path -LiteralPath $sourceFile)) {
        throw "Source file does not exist: $sourceFile"
    }

    Initialize-Directory -Path $DestDir

    $destFile = Join-Path $DestDir $FileName
    if (Test-Path -LiteralPath $destFile) {
        try {
            Remove-Item -LiteralPath $destFile -Force -ErrorAction Stop
        }
        catch {
            Write-BenchLog "Could not remove existing destination file $destFile : $($_.Exception.Message)" 'WARN'
        }
    }

    $argList = @(
        $SourceDir,
        $DestDir,
        $FileName,
        '/J',
        "/R:$script:Retries",
        "/W:$script:WaitSec",
        '/NJH',
        '/NJS',
        '/NP',
        '/NFL',
        '/NDL'
    )

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = & robocopy.exe @argList 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEap

    # Robocopy uses bit-flag exit codes. 0-7 = success / informational.
    # 8 and above include copy errors.
    $success = $false
    if ($null -ne $exitCode -and $exitCode -ge 0 -and $exitCode -lt 8) {
        $success = $true
    }

    $destExists = Test-Path -LiteralPath $destFile
    $srcSize = [int64](Get-Item -LiteralPath $sourceFile).Length
    $dstSize = [int64]0
    if ($destExists) {
        $dstSize = [int64](Get-Item -LiteralPath $destFile).Length
    }

    if ($success -and (-not $destExists -or $dstSize -ne $srcSize)) {
        $success = $false
        Write-BenchLog "Robocopy exit $exitCode but destination size mismatch for $FileName (src=$srcSize dest=$dstSize)." 'WARN'
    }

    return @{
        ExitCode   = $exitCode
        Success    = $success
        Output     = ($output | Out-String)
        DestExists = $destExists
        DestSize   = $dstSize
    }
}

function Get-Throughput {
    param(
        [Parameter(Mandatory = $true)][int64]$Bytes,
        [Parameter(Mandatory = $true)][double]$Seconds
    )

    if ($Seconds -le 0) {
        return [double]0
    }
    return [math]::Round(($Bytes / $script:BytesPerMB) / $Seconds, 2)
}

function ConvertTo-ResultObject {
    param(
        [hashtable]$Before,
        [hashtable]$After,
        [string]$TestType,
        [string]$SourceDir,
        [string]$DestDir,
        [string]$FileName,
        [int64]$FileSizeBytes,
        [double]$DurationSeconds,
        [double]$ThroughputMBps,
        [object]$ExitCode,
        [string]$Status,
        [string]$Notes
    )

    $obj = New-Object PSObject
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'Timestamp'            -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'ComputerName'         -Value $script:ComputerName
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'RunId'                -Value $script:RunId
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'TestType'             -Value $TestType
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'Source'               -Value $SourceDir
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'Destination'          -Value $DestDir
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'FileName'             -Value $FileName
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'FileSizeMB'           -Value ([math]::Round($FileSizeBytes / $script:BytesPerMB, 2))
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'DurationSeconds'      -Value ([math]::Round($DurationSeconds, 3))
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'ThroughputMBps'       -Value $ThroughputMBps
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'RobocopyExitCode'     -Value $ExitCode
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'Status'               -Value $Status
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'Notes'                -Value $Notes

    foreach ($d in $TrackedDrives) {
        $bRead  = $null
        $bWrite = $null
        $aRead  = $null
        $aWrite = $null
        if ($null -ne $Before) {
            $bRead  = $Before["${d}_AvgReadMs"]
            $bWrite = $Before["${d}_AvgWriteMs"]
        }
        if ($null -ne $After) {
            $aRead  = $After["${d}_AvgReadMs"]
            $aWrite = $After["${d}_AvgWriteMs"]
        }
        Add-Member -InputObject $obj -MemberType NoteProperty -Name "${d}_AvgReadLatencyMs_Before"  -Value $bRead
        Add-Member -InputObject $obj -MemberType NoteProperty -Name "${d}_AvgWriteLatencyMs_Before" -Value $bWrite
        Add-Member -InputObject $obj -MemberType NoteProperty -Name "${d}_AvgReadLatencyMs_After"   -Value $aRead
        Add-Member -InputObject $obj -MemberType NoteProperty -Name "${d}_AvgWriteLatencyMs_After"  -Value $aWrite
    }

    return $obj
}

function Invoke-TransferTest {
    param(
        [Parameter(Mandatory = $true)][string]$TestType,
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$DestDir,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][int64]$FileSizeBytes
    )

    Write-BenchLog "Starting $TestType : $SourceDir\$FileName -> $DestDir"

    $before = $null
    $after  = $null
    try {
        $before = Get-DiskLatencySnapshot
    }
    catch {
        Write-BenchLog "Pre-transfer latency snapshot failed: $($_.Exception.Message)" 'WARN'
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $copy = $null
    $notes = ''
    try {
        $copy = Invoke-RobocopyFile -SourceDir $SourceDir -DestDir $DestDir -FileName $FileName
    }
    catch {
        $notes = $_.Exception.Message
        $copy = @{
            ExitCode   = $null
            Success    = $false
            Output     = $notes
            DestExists = $false
            DestSize   = [int64]0
        }
        Write-BenchLog "Transfer exception: $notes" 'ERROR'
    }
    $sw.Stop()

    try {
        $after = Get-DiskLatencySnapshot
    }
    catch {
        Write-BenchLog "Post-transfer latency snapshot failed: $($_.Exception.Message)" 'WARN'
    }

    $seconds = $sw.Elapsed.TotalSeconds
    $mbps = Get-Throughput -Bytes $FileSizeBytes -Seconds $seconds
    $status = 'Failed'
    if ($copy.Success) { $status = 'Success' }

    if ($null -ne $copy.ExitCode) {
        Write-BenchLog ("{0} {1} in {2:N3}s ({3} MB/s) RobocopyExit={4}" -f $status, $FileName, $seconds, $mbps, $copy.ExitCode) $(if ($copy.Success) { 'OK' } else { 'ERROR' })
    }
    else {
        Write-BenchLog ("{0} {1} in {2:N3}s ({3} MB/s) RobocopyExit=n/a" -f $status, $FileName, $seconds, $mbps) 'ERROR'
    }

    if (-not [string]::IsNullOrWhiteSpace($copy.Output)) {
        $trimOut = $copy.Output.Trim()
        if ($trimOut.Length -gt 0) {
            Write-BenchLog ("Robocopy output: " + $trimOut)
        }
    }

    return ConvertTo-ResultObject `
        -Before $before `
        -After $after `
        -TestType $TestType `
        -SourceDir $SourceDir `
        -DestDir $DestDir `
        -FileName $FileName `
        -FileSizeBytes $FileSizeBytes `
        -DurationSeconds $seconds `
        -ThroughputMBps $mbps `
        -ExitCode $copy.ExitCode `
        -Status $status `
        -Notes $notes
}

# -----------------------------------------------------------------------------
# Aggregation
# -----------------------------------------------------------------------------
function Measure-GroupAverage {
    param(
        [Parameter(Mandatory = $true)]$Items,
        [Parameter(Mandatory = $true)][string]$GroupName,
        [Parameter(Mandatory = $true)][string]$GroupValue
    )

    $list = @($Items)
    $successItems = @($list | Where-Object { $_.Status -eq 'Success' })
    $count = $list.Count
    $successCount = $successItems.Count
    $failCount = $count - $successCount

    $avgTput = $null
    $avgDur  = $null
    $minTput = $null
    $maxTput = $null
    $avgSize = $null

    if ($successCount -gt 0) {
        $tputs = @($successItems | ForEach-Object { [double]$_.ThroughputMBps })
        $durs  = @($successItems | ForEach-Object { [double]$_.DurationSeconds })
        $sizes = @($successItems | ForEach-Object { [double]$_.FileSizeMB })
        $sumT = 0.0; foreach ($v in $tputs) { $sumT += $v }
        $sumD = 0.0; foreach ($v in $durs)  { $sumD += $v }
        $sumS = 0.0; foreach ($v in $sizes) { $sumS += $v }
        $avgTput = [math]::Round($sumT / $successCount, 2)
        $avgDur  = [math]::Round($sumD / $successCount, 3)
        $avgSize = [math]::Round($sumS / $successCount, 2)
        $minTput = ($tputs | Measure-Object -Minimum).Minimum
        $maxTput = ($tputs | Measure-Object -Maximum).Maximum
    }

    $row = New-Object PSObject
    Add-Member -InputObject $row -MemberType NoteProperty -Name 'Timestamp'           -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Add-Member -InputObject $row -MemberType NoteProperty -Name 'ComputerName'        -Value $script:ComputerName
    Add-Member -InputObject $row -MemberType NoteProperty -Name 'RunId'               -Value $script:RunId
    Add-Member -InputObject $row -MemberType NoteProperty -Name 'GroupType'           -Value $GroupName
    Add-Member -InputObject $row -MemberType NoteProperty -Name 'GroupValue'          -Value $GroupValue
    Add-Member -InputObject $row -MemberType NoteProperty -Name 'SampleCount'         -Value $count
    Add-Member -InputObject $row -MemberType NoteProperty -Name 'SuccessCount'        -Value $successCount
    Add-Member -InputObject $row -MemberType NoteProperty -Name 'FailedCount'         -Value $failCount
    Add-Member -InputObject $row -MemberType NoteProperty -Name 'AvgFileSizeMB'       -Value $avgSize
    Add-Member -InputObject $row -MemberType NoteProperty -Name 'AvgDurationSeconds'  -Value $avgDur
    Add-Member -InputObject $row -MemberType NoteProperty -Name 'AvgThroughputMBps'   -Value $avgTput
    Add-Member -InputObject $row -MemberType NoteProperty -Name 'MinThroughputMBps'   -Value $minTput
    Add-Member -InputObject $row -MemberType NoteProperty -Name 'MaxThroughputMBps'   -Value $maxTput
    return $row
}

function Export-CsvSafe {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$InputObject
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $rows = @($InputObject)
    if ($rows.Count -eq 0) {
        Write-BenchLog "No rows to export for $Path" 'WARN'
        return
    }

    $rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-BenchLog "Wrote $Path ($($rows.Count) row(s))" 'OK'
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]
$fatalMessage = $null

try {
    Initialize-Directory -Path $ReportRoot
    $script:LogPath = Join-Path $ReportRoot ("StorageBenchmark_{0}.log" -f $script:RunId)

    Write-BenchLog "============================================================"
    Write-BenchLog "Storage benchmark starting on $($script:ComputerName)"
    Write-BenchLog "RunId: $($script:RunId)"
    Write-BenchLog "PowerShell $($PSVersionTable.PSVersion)  64Bit=$([Environment]::Is64BitProcess)"
    Write-BenchLog "Source: $SourcePath"
    foreach ($t in $Targets) { Write-BenchLog ("Target {0}: {1}  (read-back to {2})" -f $t.Label, $t.Path, $t.ReadBack) }
    Write-BenchLog ("File sizes (GB): {0}" -f ($FileSizesGB -join ', '))
    Write-BenchLog "Reports: $ReportRoot"
    Write-BenchLog "============================================================"

    # --- Paths reachable ---
    foreach ($d in $TrackedDrives) {
        if (-not (Test-DriveReady -DriveLetter $d)) {
            throw "Drive ${d}: is missing or not ready."
        }
        $freeGB = [math]::Round((Get-DriveFreeSpace -DriveLetter $d) / 1GB, 2)
        Write-BenchLog "Drive ${d}: free space ${freeGB} GB"
    }

    # --- Working directories ---
    $workDirs = @($SourcePath, $ReportRoot) + @($Targets | ForEach-Object { $_.Path; $_.ReadBack })
    foreach ($dir in $workDirs) {
        try {
            Initialize-Directory -Path $dir
        }
        catch {
            throw "Unable to create or access folder '$dir': $($_.Exception.Message)"
        }
    }

    # --- Free space estimates (local drives only) ---
    $totalSourceBytes = [int64]0
    foreach ($spec in $TestFileSpecs) { $totalSourceBytes += $spec.SizeBytes }

    $needByDrive = @{}
    $srcLetter = Get-LocalDriveLetter -Path $SourcePath
    if ($srcLetter) { $needByDrive[$srcLetter] = $totalSourceBytes * (1 + $Targets.Count) }
    foreach ($t in $Targets) {
        $l = Get-LocalDriveLetter -Path $t.Path
        if ($l) {
            if (-not $needByDrive.ContainsKey($l)) { $needByDrive[$l] = [int64]0 }
            $needByDrive[$l] += $totalSourceBytes
        }
    }
    foreach ($l in $needByDrive.Keys) {
        $free = Get-DriveFreeSpace -DriveLetter $l
        if ($free -lt $needByDrive[$l]) {
            Write-BenchLog ("{0}: free space ({1:N2} GB) may be insufficient; this run needs about {2:N2} GB there." -f $l, ($free / 1GB), ($needByDrive[$l] / 1GB)) 'WARN'
        }
    }

    # Prime counter instance cache so the first transfer is not delayed.
    foreach ($d in $TrackedDrives) {
        Resolve-LogicalDiskInstance -DriveLetter $d | Out-Null
    }
    try {
        $warmup = Get-DiskLatencySnapshot
        $parts = foreach ($d in $TrackedDrives) { '{0}(R/W)={1}/{2}' -f $d, $warmup["${d}_AvgReadMs"], $warmup["${d}_AvgWriteMs"] }
        Write-BenchLog ("Warmup latency ms " + ($parts -join ' '))
    }
    catch {
        Write-BenchLog "Warmup latency collection failed: $($_.Exception.Message)" 'WARN'
    }

    # --- Create source files ---
    Write-BenchLog "Creating source test files in $SourcePath"
    foreach ($spec in $TestFileSpecs) {
        $filePath = Join-Path $SourcePath $spec.Name
        try {
            Initialize-BenchmarkFile -Path $filePath -SizeBytes $spec.SizeBytes
        }
        catch {
            throw "Failed creating $($spec.Name): $($_.Exception.Message)"
        }
    }

    $writeJobs = @($Targets | ForEach-Object { @{ TestType = 'Write'; Source = $SourcePath; Dest = $_.Path } })
    $readJobs  = @($Targets | ForEach-Object { @{ TestType = 'Read';  Source = $_.Path;     Dest = $_.ReadBack } })

    # --- Write tests ---
    Write-BenchLog "========== WRITE TESTS =========="
    foreach ($job in $writeJobs) {
        foreach ($spec in $TestFileSpecs) {
            try {
                $row = Invoke-TransferTest -TestType $job.TestType -SourceDir $job.Source -DestDir $job.Dest -FileName $spec.Name -FileSizeBytes $spec.SizeBytes
                $results.Add($row) | Out-Null
            }
            catch {
                Write-BenchLog "Write test failed for $($spec.Name) -> $($job.Dest): $($_.Exception.Message)" 'ERROR'
                $failRow = ConvertTo-ResultObject -Before $null -After $null -TestType $job.TestType -SourceDir $job.Source -DestDir $job.Dest -FileName $spec.Name -FileSizeBytes $spec.SizeBytes -DurationSeconds 0 -ThroughputMBps 0 -ExitCode $null -Status 'Failed' -Notes $_.Exception.Message
                $results.Add($failRow) | Out-Null
            }
        }
    }

    # --- Read-back tests (only if the write-side source file exists) ---
    Write-BenchLog "========== READ-BACK TESTS =========="
    foreach ($job in $readJobs) {
        foreach ($spec in $TestFileSpecs) {
            $needed = Join-Path $job.Source $spec.Name
            if (-not (Test-Path -LiteralPath $needed)) {
                Write-BenchLog "Skipping read-back of $($spec.Name) from $($job.Source); source copy is missing." 'WARN'
                $failRow = ConvertTo-ResultObject -Before $null -After $null -TestType $job.TestType -SourceDir $job.Source -DestDir $job.Dest -FileName $spec.Name -FileSizeBytes $spec.SizeBytes -DurationSeconds 0 -ThroughputMBps 0 -ExitCode $null -Status 'Failed' -Notes 'Source copy missing; write test likely failed.'
                $results.Add($failRow) | Out-Null
                continue
            }

            try {
                $row = Invoke-TransferTest -TestType $job.TestType -SourceDir $job.Source -DestDir $job.Dest -FileName $spec.Name -FileSizeBytes $spec.SizeBytes
                $results.Add($row) | Out-Null
            }
            catch {
                Write-BenchLog "Read-back test failed for $($spec.Name) -> $($job.Dest): $($_.Exception.Message)" 'ERROR'
                $failRow = ConvertTo-ResultObject -Before $null -After $null -TestType $job.TestType -SourceDir $job.Source -DestDir $job.Dest -FileName $spec.Name -FileSizeBytes $spec.SizeBytes -DurationSeconds 0 -ThroughputMBps 0 -ExitCode $null -Status 'Failed' -Notes $_.Exception.Message
                $results.Add($failRow) | Out-Null
            }
        }
    }
}
catch {
    $fatalMessage = $_.Exception.Message
    Write-BenchLog "Fatal error: $fatalMessage" 'ERROR'
}

# -----------------------------------------------------------------------------
# Reports (best-effort even after a fatal setup error, if any rows exist)
# -----------------------------------------------------------------------------
try {
    Initialize-Directory -Path $ReportRoot

    $detailPath     = Join-Path $ReportRoot ("TransferDetails_{0}.csv" -f $script:RunId)
    $perFilePath    = Join-Path $ReportRoot ("Averages_PerFile_{0}.csv" -f $script:RunId)
    $perDestPath    = Join-Path $ReportRoot ("Averages_PerDestination_{0}.csv" -f $script:RunId)
    $readWritePath  = Join-Path $ReportRoot ("Averages_ReadVsWrite_{0}.csv" -f $script:RunId)
    $overallPath    = Join-Path $ReportRoot ("Averages_Overall_{0}.csv" -f $script:RunId)
    $latestDetail   = Join-Path $ReportRoot 'TransferDetails_Latest.csv'
    $latestSummary  = Join-Path $ReportRoot 'Averages_AllGroups_Latest.csv'

    if ($results.Count -gt 0) {
        Export-CsvSafe -Path $detailPath -InputObject $results
        try { Copy-Item -LiteralPath $detailPath -Destination $latestDetail -Force } catch { Write-BenchLog "Could not update $latestDetail" 'WARN' }

        $avgRows = New-Object System.Collections.Generic.List[object]

        $fileNames = @($results | Select-Object -ExpandProperty FileName -Unique)
        foreach ($fn in $fileNames) {
            $subset = @($results | Where-Object { $_.FileName -eq $fn })
            $avgRows.Add((Measure-GroupAverage -Items $subset -GroupName 'File' -GroupValue $fn)) | Out-Null
        }
        Export-CsvSafe -Path $perFilePath -InputObject $avgRows

        $destAvgRows = New-Object System.Collections.Generic.List[object]
        $destinations = @($results | Select-Object -ExpandProperty Destination -Unique)
        foreach ($dest in $destinations) {
            $subset = @($results | Where-Object { $_.Destination -eq $dest })
            $destAvgRows.Add((Measure-GroupAverage -Items $subset -GroupName 'Destination' -GroupValue $dest)) | Out-Null
        }
        Export-CsvSafe -Path $perDestPath -InputObject $destAvgRows

        $rwRows = New-Object System.Collections.Generic.List[object]
        foreach ($tt in @('Write', 'Read')) {
            $subset = @($results | Where-Object { $_.TestType -eq $tt })
            $rwRows.Add((Measure-GroupAverage -Items $subset -GroupName 'TestType' -GroupValue $tt)) | Out-Null
        }
        Export-CsvSafe -Path $readWritePath -InputObject $rwRows

        $overall = Measure-GroupAverage -Items $results -GroupName 'Overall' -GroupValue 'AllTransfers'
        Export-CsvSafe -Path $overallPath -InputObject @($overall)

        $allGroups = @()
        $allGroups += $avgRows
        $allGroups += $destAvgRows
        $allGroups += $rwRows
        $allGroups += $overall
        Export-CsvSafe -Path $latestSummary -InputObject $allGroups
    }
    else {
        Write-BenchLog "No transfer results were collected; CSV detail reports were not written." 'WARN'
    }
}
catch {
    Write-BenchLog "Failed while writing CSV reports: $($_.Exception.Message)" 'ERROR'
}

# -----------------------------------------------------------------------------
# Console summary
# -----------------------------------------------------------------------------
Write-BenchLog "============================================================"
Write-BenchLog "BENCHMARK SUMMARY  ($($script:ComputerName) / $($script:RunId))"
if ($results.Count -gt 0) {
    $ok = @($results | Where-Object { $_.Status -eq 'Success' }).Count
    $bad = $results.Count - $ok
    Write-BenchLog "Transfers: $($results.Count)  Success: $ok  Failed: $bad"

    $colFile   = 22
    $colType   = 6
    $colDest   = 22
    $colSec    = 10
    $colMBps   = 10
    $colStat   = 8
    $hdr = ("{0,-$colFile} {1,-$colType} {2,-$colDest} {3,$colSec} {4,$colMBps} {5,-$colStat} {6}" -f 'File', 'Type', 'Destination', 'Seconds', 'MB/s', 'Status', 'Exit')
    Write-BenchLog $hdr
    foreach ($r in $results) {
        $line = ("{0,-$colFile} {1,-$colType} {2,-$colDest} {3,$colSec:N3} {4,$colMBps:N2} {5,-$colStat} {6}" -f $r.FileName, $r.TestType, $r.Destination, $r.DurationSeconds, $r.ThroughputMBps, $r.Status, $r.RobocopyExitCode)
        Write-BenchLog $line
    }

    $success = @($results | Where-Object { $_.Status -eq 'Success' })
    if ($success.Count -gt 0) {
        $writeOk = @($success | Where-Object { $_.TestType -eq 'Write' })
        $readOk  = @($success | Where-Object { $_.TestType -eq 'Read' })
        if ($writeOk.Count -gt 0) {
            $sum = 0.0; foreach ($x in $writeOk) { $sum += [double]$x.ThroughputMBps }
            Write-BenchLog ("Write average throughput: {0:N2} MB/s  (n={1})" -f ($sum / $writeOk.Count), $writeOk.Count)
        }
        if ($readOk.Count -gt 0) {
            $sum = 0.0; foreach ($x in $readOk) { $sum += [double]$x.ThroughputMBps }
            Write-BenchLog ("Read  average throughput: {0:N2} MB/s  (n={1})" -f ($sum / $readOk.Count), $readOk.Count)
        }
    }

    Write-BenchLog "Compare these numbers with the expected baseline for the disks or SAN behind each path."
    Write-BenchLog "Low MB/s or high Avg. Disk sec/Read|Write (ms) points to storage as a cause of slow file"
    Write-BenchLog "access, saves, or media transfers. Compare the write leg (source -> target) with the"
    Write-BenchLog "read-back leg (target -> source) to see which side is slower."
}
else {
    Write-BenchLog "No results to summarize."
}

if ($script:LogPath) {
    Write-BenchLog "Log file: $($script:LogPath)"
}
Write-BenchLog "Reports folder: $ReportRoot"
Write-BenchLog "============================================================"

if ($Cleanup) {
    Write-BenchLog "Cleanup: removing test files and read-back copies."
    $cleanPaths = @()
    foreach ($spec in $TestFileSpecs) {
        $cleanPaths += Join-Path $SourcePath $spec.Name
        foreach ($t in $Targets) {
            $cleanPaths += Join-Path $t.Path $spec.Name
            $cleanPaths += Join-Path $t.ReadBack $spec.Name
        }
    }
    foreach ($p in $cleanPaths) {
        if (Test-Path -LiteralPath $p) {
            try { Remove-Item -LiteralPath $p -Force -ErrorAction Stop }
            catch { Write-BenchLog "Could not remove ${p}: $($_.Exception.Message)" 'WARN' }
        }
    }
}

function Complete-BenchmarkScript {
    param([int]$Code)

    # Calling exit from PowerShell ISE closes the ISE session. Surface the
    # code without tearing down the editor.
    if ($null -ne $psISE) {
        Write-BenchLog "PowerShell ISE detected; returning instead of exit $Code."
        $global:LASTEXITCODE = $Code
        return
    }

    exit $Code
}

if ($null -ne $fatalMessage) {
    Write-Error $fatalMessage
    Complete-BenchmarkScript -Code 1
}
else {
    $failed = @($results | Where-Object { $_.Status -ne 'Success' })
    if ($failed.Count -gt 0) {
        Complete-BenchmarkScript -Code 2
    }
    else {
        Complete-BenchmarkScript -Code 0
    }
}
