# storage-benchmark

A PowerShell storage benchmark for Windows servers and workstations. It measures how fast large files really move between volumes and shares. It also records disk latency during each copy, so you can tell whether "the server is slow" is really a storage problem.

I wrote it to troubleshoot slow file opens, saves and media transfers on a file server. I needed hard numbers for both the write leg and the read-back leg, for each disk or LUN involved.

## What it does

1. Creates test files on a source volume (1, 2 and 10 GB by default).
2. **Write test:** copies each file from the source to every target path.
3. **Read test:** copies each file back from every target to a read-back folder on the source volume.
4. Uses `robocopy /J` (unbuffered I/O) for every copy, so the file-system cache does not inflate the results.
5. Samples `LogicalDisk` *Avg. Disk sec/Read* and *Avg. Disk sec/Write* for every local drive involved, before and after each copy.
6. Checks every copy: Robocopy exit code (8 or higher is a failure) plus a destination size check.
7. Writes CSV reports:
   - a detail row per transfer
   - averages by file size
   - averages by destination
   - read vs write
   - overall

Targets can be local folders on other volumes or UNC paths (SMB shares, a NAS, SAN LUNs). Latency counters are only collected for local drive letters.

## Usage

```powershell
# Local SSD vs. a second volume vs. a NAS share
.\scripts\Invoke-StorageBenchmark.ps1 `
    -SourcePath 'D:\Bench\Source' `
    -TargetPath 'E:\Bench', '\\<HOSTNAME>\share\Bench'

# Smaller files, delete everything afterwards
.\scripts\Invoke-StorageBenchmark.ps1 -SourcePath 'D:\Bench\Source' -TargetPath 'E:\Bench' -FileSizesGB 1,4 -Cleanup
```

| Parameter | Default | Purpose |
|---|---|---|
| `-SourcePath` | (required) | Where the test files are created |
| `-TargetPath` | (required) | One or more destination folders (local or UNC) |
| `-ReadBackRoot` | `<SourcePath>\..\ReadBack` | Where read-back copies land (one sub-folder per target) |
| `-FileSizesGB` | `1,2,10` | Test file sizes |
| `-ReportRoot` | `%SystemDrive%\Temp\StorageBenchmark` | Log and CSV output |
| `-RobocopyRetries` / `-RobocopyWaitSec` | `3` / `5` | Robocopy `/R` and `/W` |
| `-Cleanup` | off | Remove the test files and read-back copies at the end |

Exit codes:
- `0`: every transfer succeeded
- `1`: setup error
- `2`: one or more transfers failed

## Output

A run produces these files in `ReportRoot`. `<RunId>` is a timestamp.

| File | Contents |
|---|---|
| `StorageBenchmark_<RunId>.log` | Full log, including Robocopy output |
| `*_Detail.csv` | One row per transfer: MB/s, duration, exit code, and before/after latency per drive |
| `*_Summary_*.csv` | Averages by file size, by destination, read vs write, and overall |

## Reading the results

- **Low MB/s with high latency** (tens of ms or more) on one drive points at that disk, LUN or array.
- **Fine write leg, slow read-back** (or the reverse) tells you which direction to look at: source disk, target disk or the network path.
- **Good local numbers but slow UNC targets** point at the network or the SMB server, not the disks.

## Notes and limits

- Test files are created with `fsutil` and are zero-filled. Storage that compresses or deduplicates inline will report optimistic numbers.
- Free space needed:
  - on each target: the total of `FileSizesGB`
  - on the source volume: (1 + number of targets) x that total
- Run it elevated. Run it off-hours on production storage, because a 10 GB unbuffered copy is a real load.
- Works in Windows PowerShell 5.1 (including the ISE) and PowerShell 7.

## Testing

The script parses and passes PSScriptAnalyzer with the included settings. It is **Windows-only and has been tested for syntax only in this repo.** Validate it on a non-production system before you rely on the numbers.

## License

MIT, see [LICENSE](LICENSE).
