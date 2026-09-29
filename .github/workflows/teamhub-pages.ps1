# Builds the vault's GitHub Pages file browser: a thumbnail per SolidWorks
# file plus a manifest.json the static index page renders. Runs on a
# GitHub-hosted runner (see teamhub-pages.yml) and equally from a workstation.
#
# Thumbnails come from the preview PNG SolidWorks embeds in every file it
# saves, decoded here directly, so no SolidWorks or eDrawings licence is
# involved. A thumbnail is keyed by the file's git blob id and kept in the
# site between runs, so a push only downloads (LFS) and decodes the files
# whose content actually changed.
#
# Kept Windows PowerShell 5.1-clean (tests/pages-build-test.ps1 dot-sources
# it there) and saved as UTF-8 with BOM, like teamhub-workflow.ps1.
[CmdletBinding()]
param(
    [string]$VaultPath = '.',
    # The site folder, normally a worktree of the gh-pages branch.
    [Parameter(Mandatory)][string]$SiteDir,
    # owner/repo and the branch the download links point at.
    [string]$Repo = $env:GITHUB_REPOSITORY,
    [string]$Branch = 'main',
    [string[]]$Exclude = @('Trash/*'),
    # Defaults to the page next to this script.
    [string]$IndexTemplate,
    # Commit the site folder when anything changed (the workflow pushes).
    [switch]$Commit
)

$ErrorActionPreference = 'Stop'
$CadPattern = '\.(sldprt|sldasm|slddrw)$'

if (-not ('SwPreview' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;

public static class SwPreview {
    // SolidWorks 2015+ files are a run of sections, each
    //   14 00 06 00 08 00 | u32 | u32 crc | u32 packed | u32 unpacked | u32 nameLen | name | raw deflate
    // with every name byte nibble-swapped. The preview is a section named
    // "PreviewPNG"; stale copies with junk headers also carry that name, so
    // take the largest one that actually inflates to a PNG.
    public static byte[] Extract(byte[] b) {
        byte[] best = null;
        for (int i = 0; i + 26 < b.Length; i++) {
            if (b[i] != 0x14 || b[i+1] != 0 || b[i+2] != 6 || b[i+3] != 0 || b[i+4] != 8 || b[i+5] != 0) continue;
            uint packed = BitConverter.ToUInt32(b, i + 14);
            uint unpacked = BitConverter.ToUInt32(b, i + 18);
            uint nameLen = BitConverter.ToUInt32(b, i + 22);
            if (nameLen != 10 || packed < 64 || unpacked < 64 || unpacked > (32u << 20)) continue;
            long data = i + 26 + nameLen;
            if (data + packed > b.Length) continue;
            if (Name(b, i + 26, (int)nameLen) != "PreviewPNG") continue;
            try {
                var png = new MemoryStream();
                using (var z = new DeflateStream(new MemoryStream(b, (int)data, (int)packed), CompressionMode.Decompress))
                    z.CopyTo(png);
                var bytes = png.ToArray();
                if (bytes.Length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47
                    && (best == null || bytes.Length > best.Length))
                    best = bytes;
            } catch (InvalidDataException) { }
        }
        return best;
    }

    static string Name(byte[] b, int at, int len) {
        var c = new char[len];
        for (int k = 0; k < len; k++) { int x = b[at + k]; c[k] = (char)(((x << 4) & 0xF0) | (x >> 4)); }
        return new string(c);
    }
}
'@
}

function Invoke-Git {
    param([string]$Dir, [Parameter(ValueFromRemainingArguments)][string[]]$GitArgs)
    $out = & git -C $Dir -c core.quotepath=false @GitArgs
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed ($LASTEXITCODE)" }
    $out
}

# Runs git with stdin/stdout as raw bytes (PowerShell pipes would re-encode
# binary content as text).
function Invoke-GitBytes {
    param([string]$Dir, [string[]]$GitArgs, [byte[]]$InputBytes)
    $psi = New-Object Diagnostics.ProcessStartInfo 'git'
    $psi.Arguments = (@('-C', $Dir) + $GitArgs | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # .NET Framework builds the stdin writer from Console.InputEncoding, and a
    # UTF-8 console encoding there comes with a BOM that lands in front of the
    # first line git reads. Swap in a BOM-less encoding just for the start.
    $saved = $null
    try { $saved = [Console]::InputEncoding; [Console]::InputEncoding = New-Object Text.UTF8Encoding $false } catch { }
    try { $p = [Diagnostics.Process]::Start($psi) }
    finally { if ($saved) { try { [Console]::InputEncoding = $saved } catch { } } }
    $errTask = $p.StandardError.ReadToEndAsync()
    # Drain stdout while stdin is still being written, or a large output
    # (cat-file --batch) fills the pipe and both sides wait forever.
    $ms = New-Object IO.MemoryStream
    $outTask = $p.StandardOutput.BaseStream.CopyToAsync($ms)
    if ($InputBytes) { $p.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Length) }
    $p.StandardInput.Close()
    $outTask.Wait()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "git $($GitArgs -join ' ') failed: $($errTask.Result.Trim())" }
    , $ms.ToArray()
}

# Reads many blobs through one `git cat-file --batch`: blob id -> bytes.
function Read-Blobs([string]$Dir, [string[]]$Ids) {
    $result = @{}
    if (-not $Ids) { return $result }
    $raw = Invoke-GitBytes $Dir @('cat-file', '--batch') ([Text.Encoding]::ASCII.GetBytes(($Ids -join "`n") + "`n"))
    $at = 0
    while ($at -lt $raw.Length) {
        $nl = [Array]::IndexOf($raw, [byte]10, $at)
        $header = [Text.Encoding]::ASCII.GetString($raw, $at, $nl - $at).Split(' ')
        if ($header.Count -lt 3) { $at = $nl + 1; continue }   # "<id> missing"
        $len = [int]$header[2]
        $bytes = New-Object byte[] $len
        [Array]::Copy($raw, $nl + 1, $bytes, 0, $len)
        $result[$header[0]] = $bytes
        $at = $nl + 1 + $len + 1
    }
    $result
}

function Test-Excluded([string]$Path, [string[]]$Patterns) {
    foreach ($x in $Patterns) { if ($x -and $Path -like $x) { return $true } }
    $false
}

# Parses a git-lfs pointer; $null when the blob is ordinary content.
function Read-LfsPointer([byte[]]$Blob) {
    if ($Blob.Length -gt 1024) { return $null }
    $text = [Text.Encoding]::ASCII.GetString($Blob)
    if ($text -notmatch '^version https://git-lfs\.github\.com/spec/v1') { return $null }
    $oid = [regex]::Match($text, 'oid sha256:([0-9a-f]{64})').Groups[1].Value
    $size = [regex]::Match($text, '(?m)^size (\d+)').Groups[1].Value
    New-Object psobject -Property @{ Oid = $oid; Size = [long]$size }
}

# The file's real bytes: from the local LFS store when present, otherwise
# downloaded by git-lfs itself (auth and endpoint as git already has them).
function Get-FileBytes([string]$Vault, [string]$GitDir, [string]$Path, [byte[]]$Blob, $Pointer) {
    if (-not $Pointer) { return , $Blob }
    $local = Join-Path $GitDir ("lfs/objects/{0}/{1}/{2}" -f $Pointer.Oid.Substring(0, 2), $Pointer.Oid.Substring(2, 2), $Pointer.Oid)
    if (Test-Path -LiteralPath $local) { return , [IO.File]::ReadAllBytes($local) }
    , (Invoke-GitBytes $Vault @('lfs', 'smudge', '--', $Path) $Blob)
}

function Build-Site {
    $vault = (Resolve-Path $VaultPath).Path
    $site = (New-Item -ItemType Directory -Force $SiteDir).FullName
    $thumbDir = Join-Path $site 'thumbs'
    New-Item -ItemType Directory -Force $thumbDir | Out-Null
    $gitDir = (Invoke-Git $vault rev-parse --absolute-git-dir)
    $head = (Invoke-Git $vault rev-parse HEAD)

    # Blob ids already decoded by an earlier run and found to have no preview,
    # so they are not downloaded again just to fail again.
    $noPreview = @{}
    $old = $null; $oldRepo = $null; $oldBranch = $null
    $oldManifest = Join-Path $site 'manifest.json'
    if (Test-Path $oldManifest) {
        try {
            $old = Get-Content $oldManifest -Raw -Encoding UTF8 | ConvertFrom-Json
            $oldRepo = $old.repo; $oldBranch = $old.branch
            foreach ($f in $old.files) {
                if (-not $f.thumb) { $noPreview[$f.blob] = $true }
            }
        } catch { Write-Warning "ignoring unreadable manifest.json: $_" }
    }

    # Tracked CAD files at HEAD.
    $entries = @()
    foreach ($line in (Invoke-Git $vault ls-tree -r HEAD)) {
        $tab = $line.IndexOf([char]9)   # char overload: ordinal on every platform
        $meta = $line.Substring(0, $tab).Split(' ')
        $path = $line.Substring($tab + 1)
        if ($meta[1] -ne 'blob' -or $path -notmatch $CadPattern) { continue }
        if (Test-Excluded $path $Exclude) { continue }
        $entries += New-Object psobject -Property @{ Path = $path; Blob = $meta[2] }
    }

    # Last commit per path: one history walk, newest first, first sighting wins.
    $lastCommit = @{}
    $current = $null
    foreach ($line in (Invoke-Git $vault log --format=%x01%H%x1f%an%x1f%aI%x1f%s --name-only HEAD)) {
        # A char test, not StartsWith: on Linux .NET compares strings through
        # ICU, which ignores \x01 and so matches every line, blank ones too.
        if ($line.Length -gt 0 -and $line[0] -eq [char]1) {
            $p = $line.Substring(1).Split([char]0x1f)
            $current = [ordered]@{ sha = $p[0]; author = $p[1]; date = $p[2]; subject = $p[3] }
        } elseif ($line -and $current -and -not $lastCommit.ContainsKey($line)) {
            $lastCommit[$line] = $current
        }
    }

    $blobs = Read-Blobs $vault @($entries | ForEach-Object { $_.Blob } | Select-Object -Unique)
    $files = @()
    $kept = @{}
    $decoded = 0
    foreach ($e in $entries) {
        $blob = $blobs[$e.Blob]
        $pointer = Read-LfsPointer $blob
        $size = if ($pointer) { $pointer.Size } else { $blob.Length }

        $thumbName = "$($e.Blob).png"
        $thumbPath = Join-Path $thumbDir $thumbName
        $thumb = $null
        if (Test-Path $thumbPath) {
            $thumb = "thumbs/$thumbName"
        } elseif (-not $noPreview.ContainsKey($e.Blob)) {
            try {
                $png = [SwPreview]::Extract((Get-FileBytes $vault $gitDir $e.Path $blob $pointer))
                $decoded++
                if ($png) {
                    [IO.File]::WriteAllBytes($thumbPath, $png)
                    $thumb = "thumbs/$thumbName"
                }
            } catch {
                Write-Warning "no thumbnail for $($e.Path): $($_.Exception.Message)"
            }
        }
        if ($thumb) { $kept[$thumbName] = $true }

        $state = $null
        $card = Join-Path $vault ($e.Path + '.card.json')
        if (Test-Path -LiteralPath $card) {
            try { $state = (Get-Content -LiteralPath $card -Raw -Encoding UTF8 | ConvertFrom-Json).state } catch { }
        }

        $ext = [IO.Path]::GetExtension($e.Path).TrimStart('.').ToLowerInvariant()
        $files += [ordered]@{
            path   = $e.Path
            type   = @{ sldprt = 'part'; sldasm = 'assembly'; slddrw = 'drawing' }[$ext]
            size   = $size
            blob   = $e.Blob
            lfs    = [bool]$pointer
            thumb  = $thumb
            state  = $state
            commit = $lastCommit[$e.Path]
        }
    }

    # Thumbnails of content no longer at HEAD.
    foreach ($t in (Get-ChildItem $thumbDir -Filter *.png)) {
        if (-not $kept.ContainsKey($t.Name)) { Remove-Item $t.FullName }
    }

    # Rewritten only when the file list changed, so a push that touches no CAD
    # file leaves the site alone; "commit" is then the last one that did.
    # Both sides go through the same JSON round trip (a "files" property), so
    # how each PowerShell edition unrolls arrays cannot make them differ.
    $normalise = { param($json) ConvertTo-Json -InputObject (('{"files":' + $json + '}') | ConvertFrom-Json) -Depth 6 -Compress }
    $current = & $normalise (ConvertTo-Json -InputObject @($files) -Depth 5 -Compress)
    $previous = $null
    if ($old) {
        try { $previous = & $normalise (ConvertTo-Json -InputObject @($old.files) -Depth 5 -Compress) } catch { }
    }
    if ($current -ne $previous -or $Repo -ne $oldRepo -or $Branch -ne $oldBranch) {
        $manifest = [ordered]@{
            repo      = $Repo
            branch    = $Branch
            commit    = $head
            generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            files     = $files
        }
        $json = ConvertTo-Json $manifest -Depth 5 -Compress
        [IO.File]::WriteAllText($oldManifest, $json, (New-Object Text.UTF8Encoding $false))
    }
    $template = $IndexTemplate
    if (-not $template) { $template = Join-Path $PSScriptRoot 'teamhub-pages-index.html' }
    Copy-Item $template (Join-Path $site 'index.html') -Force
    # Serve thumbs/ and manifest.json as-is, no Jekyll pass.
    if (-not (Test-Path (Join-Path $site '.nojekyll'))) { New-Item -ItemType File (Join-Path $site '.nojekyll') | Out-Null }

    $withThumb = @($files | Where-Object { $_.thumb }).Count
    Write-Host ("{0} files, {1} with a thumbnail, {2} decoded this run" -f $files.Count, $withThumb, $decoded)

    if ($Commit) {
        Invoke-Git $site add -A | Out-Null
        & git -C $site diff --cached --quiet
        if ($LASTEXITCODE -eq 0) { Write-Host 'site unchanged'; return }
        Invoke-Git $site commit -q -m "Site for $($head.Substring(0, 7))" | Out-Null
        Write-Host 'site committed'
    }
}

# Dot-sourcing (the test) loads the functions without building.
if ($MyInvocation.InvocationName -ne '.') { Build-Site }
