param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    $script:failures.Add($Message) | Out-Null
}

function Read-RepoText {
    param([string]$RelativePath)
    return Get-Content -LiteralPath (Join-Path $Root $RelativePath) -Raw
}

function Get-XciParam {
    param($Params, [string]$Name)
    $prop = $Params.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value[0].value
}

function Convert-CoeDwordToHostHex {
    param([string]$Raw)
    return ($Raw.Substring(6, 2) + $Raw.Substring(4, 2) + $Raw.Substring(2, 2) + $Raw.Substring(0, 2)).ToUpperInvariant()
}

function Get-CfgspaceHostDwords {
    param([string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw
    $values = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($raw, '(?i)\b[0-9a-f]{8}\b')) {
        $values.Add((Convert-CoeDwordToHostHex $m.Value)) | Out-Null
    }
    return $values.ToArray()
}

function Get-SourceFiles {
    $roots = @('src', 'ip_captaindma_75t', 'ip_captaindma_100t', 'ip_zdma_100t')
    foreach ($rel in $roots) {
        Get-ChildItem -LiteralPath (Join-Path $Root $rel) -Recurse -File
    }
    foreach ($pattern in @('*.tcl', '*.bat', '*.md', 'LICENSE')) {
        Get-ChildItem -LiteralPath $Root -File -Filter $pattern
    }
}

$nvme = Read-RepoText 'src/pcileech_nvme_dma_disk.sv'
$profile = Read-RepoText 'src/nvme_board_profile.svh'
$bar = Read-RepoText 'src/pcileech_tlps128_bar_controller.sv'
$ft601 = Read-RepoText 'src/pcileech_ft601.sv'
$pcieCfg = Read-RepoText 'src/pcileech_pcie_cfg_a7.sv'
$tcl = Read-RepoText 'vivado_ip_import.tcl'
$tcl75 = Read-RepoText 'vivado_generate_project_captain_75T.tcl'
$tclZdma = Read-RepoText 'vivado_generate_project_zdma_100T.tcl'

if ($profile -match 'NVME_BACKING_LBAS') {
    Add-Failure 'NVME_BACKING_LBAS must not exist; backing size must derive from NVME_BACKING_SLOT_BITS.'
}
if ($nvme -match 'block_store[0-3]\[') {
    Add-Failure 'Legacy split backing RAM found; backing cache must use a single inferred memory.'
}
if ($bar -match "f_tdata\[31:29\]\s*==\s*8'b") {
    Add-Failure 'BAR write engine compares a 3-bit field against an 8-bit literal.'
}
if ($bar -notmatch 'default:\s*begin\s*state\s*<=\s*`S_ENGINE_IDLE;') {
    Add-Failure 'BAR write engine state machine must have a safe default branch.'
}
if ($ft601 -notmatch 'default:\s*state\s*<=\s*`S_FT601_IDLE;') {
    Add-Failure 'FT601 state machine must have a safe default branch.'
}
if ($nvme -match 'ST_DSM_CLEAR') {
    Add-Failure 'DSM/TRIM must invalidate matching cache tags instead of using the old sequential clear state.'
}
if ($nvme -notmatch 'ST_DSM_INVALIDATE') {
    Add-Failure 'DSM/TRIM cache invalidation state is missing.'
}
if ($nvme -notmatch 'ST_DSM_VALIDATE_2') {
    Add-Failure 'DSM range validation must be pipelined before error logging and cache invalidation.'
}
if ($nvme -match "lba_range_ok\(32''d1") {
    Add-Failure 'DSM range validation must not call lba_range_ok directly on the completion timing path.'
}
if ($nvme -match 'stat_prp_list_fetches\s*<=\s*stat_prp_list_fetches\s*\+\s*\{56''h00000000000000,\s*last_entry\}') {
    Add-Failure 'PRP list statistics must not add last_entry on the command setup timing path.'
}
if ($nvme -match '/\s*32''d1000') {
    Add-Failure 'SMART data-unit accounting must not infer a wide divider on the command timing path.'
}
if ($pcieCfg -match 'rw\[21\]\s*<=\s*1') {
    Add-Failure 'PCIe command register auto-set must be disabled at reset; the host must own Memory Space and Bus Master enable.'
}
if ($tcl -match 'GENERATE_SYNTH_CHECKPOINT\s+true\s+\$ips') {
    Add-Failure 'GENERATE_SYNTH_CHECKPOINT is being set on get_ips output instead of XCI file objects.'
}
if ($tcl -notmatch 'get_files\s+-quiet\s+-all\s+-of_objects\s+\$ip') {
    Add-Failure 'Vivado IP import must resolve imported XCI file objects via get_files -of_objects $ip.'
}
if ($tcl -notmatch 'No XCI files found') {
    Add-Failure 'Vivado IP import should fail fast when a board IP directory has no XCI files.'
}
if ($tcl -match 'No imported XCI file object found') {
    Add-Failure 'Vivado IP import must not hard-fail when a locked IP does not expose an XCI file object.'
}
if ($tcl -match '(?m)^\s*synth_ip\b') {
    Add-Failure 'Vivado project-mode flow must not call synth_ip directly.'
}
if ($tcl -notmatch 'vivado_job_count') {
    Add-Failure 'Vivado build flow should derive launch job count from the host or NVME_VIVADO_JOBS.'
}
if ($tcl -notmatch 'set_param\s+general\.maxThreads') {
    Add-Failure 'Vivado build flow should set general.maxThreads for local builds.'
}
if ($tcl -match 'launch_runs\s+\S+\s+(?:-to_step\s+\S+\s+)?-jobs\s+6') {
    Add-Failure 'Vivado build flow must not be capped at the old fixed 6 jobs.'
}
if ($tcl -notmatch 'USED_IN_SYNTHESIS\s+false') {
    Add-Failure 'Vivado IP import should disable generated in-context clock XDC files for top-level synthesis.'
}
if ($tcl -notmatch 'USED_IN_IMPLEMENTATION\s+false') {
    Add-Failure 'Vivado IP import should disable generated in-context clock XDC files for top-level implementation.'
}
if ($tcl -notmatch 'skip_ip_names') {
    Add-Failure 'Vivado IP import should support skipping board IPs that are already provided by board netlists.'
}
if ($tclZdma -notmatch 'fifo_64_64_clk2_comrx') {
    Add-Failure 'ZDMA project generation must skip fifo_64_64_clk2_comrx.xci because pcileech_com_e.v already defines it.'
}
if ($tcl75 -notmatch 'RuntimeOptimized') {
    Add-Failure '75T build should use the runtime-optimized synthesis directive to avoid long cross-boundary optimization stalls.'
}
if ($tcl75 -notmatch 'ExploreArea') {
    Add-Failure '75T implementation should use an area-oriented opt_design directive.'
}
if ($tcl75 -notmatch 'CONTROL_SET_OPT_THRESHOLD\s+16') {
    Add-Failure '75T build should enable control-set optimization for slice packing.'
}

$slotMatches = [regex]::Matches($profile, 'NVME_BACKING_SLOT_BITS\s+([0-9]+)')
if ($slotMatches.Count -eq 0) {
    Add-Failure 'No NVME_BACKING_SLOT_BITS values found.'
}
$profile75 = [regex]::Match($profile, '(?s)`ifdef\s+NVME_PROFILE_75T(.*?)`elsif')
if (!$profile75.Success) {
    Add-Failure '75T profile block is missing.'
} else {
    $slot75 = [regex]::Match($profile75.Groups[1].Value, 'NVME_BACKING_SLOT_BITS\s+([0-9]+)')
    $mdts75 = [regex]::Match($profile75.Groups[1].Value, 'NVME_MDTS\s+8''d([0-9]+)')
    if (!$slot75.Success -or !$mdts75.Success) {
        Add-Failure '75T profile resource fields are incomplete.'
    } else {
        if ([int]$slot75.Groups[1].Value -gt 1) {
            Add-Failure '75T backing cache is too large for reliable placement on xc7a75t.'
        }
        if ([int]$mdts75.Groups[1].Value -gt 2) {
            Add-Failure '75T MDTS is too large for the lite placement profile.'
        }
    }
}
foreach ($m in $slotMatches) {
    $slotBits = [int]$m.Groups[1].Value
    $indexBits = $slotBits + 7
    $cacheBits = [int][math]::Pow(2, $indexBits) * 32
    if ($slotBits -lt 1 -or $slotBits -gt 7) {
        Add-Failure "Unsupported NVME_BACKING_SLOT_BITS=$slotBits; expected 1..7 for this Artix-7 profile set."
    }
    if ($cacheBits -gt 600000) {
        Add-Failure "Backing cache is too large for this build profile: slot_bits=$slotBits cache_bits=$cacheBits."
    }
}

$mdtsMatches = [regex]::Matches($profile, 'NVME_MDTS\s+8''d([0-9]+)')
$xferMatches = [regex]::Matches($profile, 'NVME_MAX_XFER_DW\s+20''d([0-9]+)')
$prpMatches = [regex]::Matches($profile, 'NVME_PRP_LIST_BITS\s+([0-9]+)')
if (($mdtsMatches.Count -ne $xferMatches.Count) -or ($mdtsMatches.Count -ne $prpMatches.Count)) {
    Add-Failure 'NVME_MDTS, NVME_MAX_XFER_DW, and NVME_PRP_LIST_BITS profile counts do not match.'
}
for ($i = 0; $i -lt [Math]::Min($mdtsMatches.Count, [Math]::Min($xferMatches.Count, $prpMatches.Count)); $i++) {
    $mdts = [int]$mdtsMatches[$i].Groups[1].Value
    $xferDw = [int]$xferMatches[$i].Groups[1].Value
    $prpBits = [int]$prpMatches[$i].Groups[1].Value
    $expectedDw = [int][math]::Pow(2, 10 + $mdts)
    if ($xferDw -ne $expectedDw) {
        Add-Failure "MAX_XFER_DW mismatch for MDTS=$mdts; expected $expectedDw, got $xferDw."
    }
    $maxBytes = $xferDw * 4
    $worstListEntries = [int][math]::Ceiling(([math]::Max(0, $maxBytes - 4)) / 4096.0)
    $listEntries = [int][math]::Pow(2, $prpBits)
    if ($listEntries -lt $worstListEntries) {
        Add-Failure "PRP list too small for MDTS=$mdts; need at least $worstListEntries entries, got $listEntries."
    }
}

$badPatterns = @(
    '01020801',
    'Revision_ID"\s*:\s*\[\s*\{\s*"value"\s*:\s*"01"',
    'BAR0_Size_Vector"\s*:\s*\[\s*\{\s*"value"\s*:\s*"16K"',
    'Other_memory_controller',
    'RAID_controller'
)
foreach ($pattern in $badPatterns) {
    $hits = Get-SourceFiles |
        Where-Object {
            ($_.FullName -notmatch '\\src\\pcileech_com_e\.v$') -and
            ($_.FullName -notmatch '\\tools\\sanity_check\.ps1$')
        } |
        Select-String -Pattern $pattern -ErrorAction SilentlyContinue
    if ($hits) {
        Add-Failure "Legacy bad pattern found: $pattern"
    }
}

$xdcExpect = @(
    @{ File = 'src/pcileech_75t484_x1_captaindma_75t.xdc'; Patterns = @('GTPE2_CHANNEL_X0Y7', 'IBUFDS_GTE2_X0Y3') },
    @{ File = 'src/pcileech_100t484_x1_captaindma_100t.xdc'; Patterns = @('GTPE2_CHANNEL_X0Y7', 'IBUFDS_GTE2_X0Y3') },
    @{ File = 'src/pcileech_tbx4_100t.xdc'; Patterns = @('GTPE2_CHANNEL_X0Y4', 'GTPE2_CHANNEL_X0Y5', 'GTPE2_CHANNEL_X0Y6', 'GTPE2_CHANNEL_X0Y7', 'IBUFDS_GTE2_X0Y3') }
)
foreach ($check in $xdcExpect) {
    $xdc = Read-RepoText $check.File
    foreach ($pattern in $check.Patterns) {
        if ($xdc -notmatch [regex]::Escape($pattern)) {
            Add-Failure "$($check.File) missing placement constraint: $pattern"
        }
    }
}

$xdcZdma = Read-RepoText 'src/pcileech_tbx4_100t.xdc'
$zdmaLaneExpect = @(
    'GTPE2_CHANNEL_X0Y7 .*pipe_lane\[0\]',
    'GTPE2_CHANNEL_X0Y6 .*pipe_lane\[1\]',
    'GTPE2_CHANNEL_X0Y5 .*pipe_lane\[2\]',
    'GTPE2_CHANNEL_X0Y4 .*pipe_lane\[3\]',
    'PACKAGE_PIN C9\s+\[get_ports pcie_rx_n\[0\]\]',
    'PACKAGE_PIN D9\s+\[get_ports pcie_rx_p\[0\]\]',
    'PACKAGE_PIN C7\s+\[get_ports pcie_tx_n\[0\]\]',
    'PACKAGE_PIN D7\s+\[get_ports pcie_tx_p\[0\]\]',
    'PACKAGE_PIN A8\s+\[get_ports pcie_rx_n\[3\]\]',
    'PACKAGE_PIN B8\s+\[get_ports pcie_rx_p\[3\]\]',
    'PACKAGE_PIN A4\s+\[get_ports pcie_tx_n\[3\]\]',
    'PACKAGE_PIN B4\s+\[get_ports pcie_tx_p\[3\]\]'
)
foreach ($pattern in $zdmaLaneExpect) {
    if ($xdcZdma -notmatch $pattern) {
        Add-Failure "ZDMA x4 lane-reversal constraint missing or wrong: $pattern"
    }
}

$boardDirs = @('ip_captaindma_75t', 'ip_captaindma_100t', 'ip_zdma_100t')
foreach ($dir in $boardDirs) {
    $pcieXci = Join-Path $Root "$dir/pcie_7x_0.xci"
    if (!(Test-Path -LiteralPath $pcieXci)) {
        Add-Failure "Missing PCIe XCI: $dir/pcie_7x_0.xci"
        continue
    }
    try {
        $json = Get-Content -LiteralPath $pcieXci -Raw | ConvertFrom-Json
    } catch {
        Add-Failure "Invalid XCI JSON: $dir/pcie_7x_0.xci"
        continue
    }
    $params = $json.ip_inst.parameters.component_parameters
    $expect = @{
        Vendor_ID = '144D'
        Device_ID = 'A80A'
        Revision_ID = '02'
        Subsystem_Vendor_ID = '144D'
        Subsystem_ID = 'A801'
        Class_Code_Base = '01'
        Class_Code_Sub = '00'
        Class_Code_Interface = '00'
        Bar0_Enabled = 'true'
        Bar0_Type = 'Memory'
        Bar0_64bit = 'false'
        Bar0_Prefetchable = 'false'
        Bar0_Scale = 'Megabytes'
        Bar0_Size = '1'
    }
    foreach ($key in $expect.Keys) {
        $actual = Get-XciParam $params $key
        if ($actual -ne $expect[$key]) {
            Add-Failure "$dir pcie_7x_0.xci $key expected $($expect[$key]), got $actual."
        }
    }

    $coe = Join-Path $Root "$dir/pcileech_cfgspace.coe"
    if (!(Test-Path -LiteralPath $coe)) {
        Add-Failure "Missing cfgspace COE: $dir/pcileech_cfgspace.coe"
    } else {
        $cfgWords = Get-CfgspaceHostDwords $coe
        $cfgExpect = @(
            @{ Offset = 0x00; Value = 'A80A144D'; Name = 'VID/DID' },
            @{ Offset = 0x04; Value = '00100000'; Name = 'reset command/status' },
            @{ Offset = 0x08; Value = '01080202'; Name = 'revision/class' },
            @{ Offset = 0x10; Value = '00000000'; Name = 'BAR0 reset value' },
            @{ Offset = 0x34; Value = '00000040'; Name = 'capability pointer' },
            @{ Offset = 0xB0; Value = '00010011'; Name = 'MSI-X capability' },
            @{ Offset = 0xB4; Value = '00003000'; Name = 'MSI-X table' },
            @{ Offset = 0xB8; Value = '00003800'; Name = 'MSI-X PBA' }
        )
        foreach ($item in $cfgExpect) {
            $index = [int]($item.Offset / 4)
            if ($cfgWords.Count -le $index) {
                Add-Failure "$dir cfgspace too short for offset 0x$($item.Offset.ToString('X2'))."
                continue
            }
            if ($cfgWords[$index] -ne $item.Value) {
                Add-Failure "$dir cfgspace $($item.Name) at 0x$($item.Offset.ToString('X2')) expected $($item.Value), got $($cfgWords[$index])."
            }
        }
    }
}

$boardDirs | ForEach-Object {
    Get-ChildItem -LiteralPath (Join-Path $Root $_) -Filter '*.xci' -File | ForEach-Object {
        try {
            Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json | Out-Null
        } catch {
            Add-Failure "Invalid XCI JSON: $($_.FullName)"
        }
    }
}

Get-ChildItem -LiteralPath $Root -Filter 'generate*.bat' | ForEach-Object {
    if ($_.Name -match [char]0x2013) {
        Add-Failure "Batch filename contains an en dash: $($_.Name)"
    }
}

Get-ChildItem -LiteralPath $Root -Filter 'vivado_generate_project_*.tcl' | ForEach-Object {
    $content = Get-Content -LiteralPath $_.FullName -Raw
    foreach ($m in [regex]::Matches($content, '"\$origin_dir/([^"]+)"')) {
        $rel = $m.Groups[1].Value
        if ($rel -like '*$*') { continue }
        if (!(Test-Path -LiteralPath (Join-Path $Root $rel))) {
            Add-Failure "$($_.Name) references missing file: $rel"
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host "Sanity check failed:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
}

Write-Host "Sanity check passed." -ForegroundColor Green
