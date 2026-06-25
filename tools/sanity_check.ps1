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

$nvme = Read-RepoText 'src/pcileech_nvme_dma_disk.sv'
$profile = Read-RepoText 'src/nvme_board_profile.svh'
$bar = Read-RepoText 'src/pcileech_tlps128_bar_controller.sv'
$ft601 = Read-RepoText 'src/pcileech_ft601.sv'
$tcl = Read-RepoText 'vivado_ip_import.tcl'

if ($profile -match 'NVME_BACKING_LBAS') {
    Add-Failure 'NVME_BACKING_LBAS must not exist; backing size must derive from NVME_BACKING_SLOT_BITS.'
}
if ($nvme -match 'block_store\[') {
    Add-Failure 'Direct block_store[] access found; backing cache must stay banked.'
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
if ($tcl -match 'GENERATE_SYNTH_CHECKPOINT\s+true\s+\$ips') {
    Add-Failure 'GENERATE_SYNTH_CHECKPOINT is being set on get_ips output instead of XCI file objects.'
}
if ($tcl -notmatch 'get_files\s+-quiet\s+-of_objects\s+\$ip') {
    Add-Failure 'Vivado IP import must resolve imported XCI file objects via get_files -of_objects $ip.'
}
if ($tcl -notmatch 'No XCI files found') {
    Add-Failure 'Vivado IP import should fail fast when a board IP directory has no XCI files.'
}

$slotMatches = [regex]::Matches($profile, 'NVME_BACKING_SLOT_BITS\s+([0-9]+)')
if ($slotMatches.Count -eq 0) {
    Add-Failure 'No NVME_BACKING_SLOT_BITS values found.'
}
foreach ($m in $slotMatches) {
    $slotBits = [int]$m.Groups[1].Value
    $indexBits = $slotBits + 7
    $bankBits = ([int][math]::Pow(2, $indexBits) / 4) * 32
    if ($slotBits -lt 7 -or $slotBits -gt 9) {
        Add-Failure "Unsupported NVME_BACKING_SLOT_BITS=$slotBits; expected 7..9 for this Artix-7 profile set."
    }
    if ($bankBits -ge 1000000) {
        Add-Failure "Backing cache bank is too large for Vivado variable limit: slot_bits=$slotBits bank_bits=$bankBits."
    }
}

$mdtsMatches = [regex]::Matches($profile, 'NVME_MDTS\s+8''d([0-9]+)')
$xferMatches = [regex]::Matches($profile, 'NVME_MAX_XFER_DW\s+20''d([0-9]+)')
if ($mdtsMatches.Count -ne $xferMatches.Count) {
    Add-Failure 'NVME_MDTS and NVME_MAX_XFER_DW profile counts do not match.'
}
for ($i = 0; $i -lt [Math]::Min($mdtsMatches.Count, $xferMatches.Count); $i++) {
    $mdts = [int]$mdtsMatches[$i].Groups[1].Value
    $xferDw = [int]$xferMatches[$i].Groups[1].Value
    $expectedDw = [int][math]::Pow(2, 10 + $mdts)
    if ($xferDw -ne $expectedDw) {
        Add-Failure "MAX_XFER_DW mismatch for MDTS=$mdts; expected $expectedDw, got $xferDw."
    }
}

$badPatterns = @(
    '01020801',
    'Revision_ID"\s*:\s*\[\s*\{\s*"value"\s*:\s*"01"',
    'BAR0_Size_Vector"\s*:\s*\[\s*\{\s*"value"\s*:\s*"16K"',
    'Sub_Class_Interface_Menu',
    'RAID_controller'
)
foreach ($pattern in $badPatterns) {
    $hits = Get-ChildItem -LiteralPath $Root -Recurse -File |
        Where-Object {
            ($_.FullName -notmatch '\\src\\pcileech_com_e\.v$') -and
            ($_.FullName -notmatch '\\tools\\sanity_check\.ps1$')
        } |
        Select-String -Pattern $pattern -ErrorAction SilentlyContinue
    if ($hits) {
        Add-Failure "Legacy bad pattern found: $pattern"
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
        Class_Code_Sub = '08'
        Class_Code_Interface = '02'
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
        $firstCfg = Get-Content -LiteralPath $coe | Where-Object { $_ -match '^4d14' } | Select-Object -First 1
        if ($firstCfg -ne '4d140aa8,06041000,02020801,10000000,') {
            Add-Failure "$dir cfgspace first row mismatch: $firstCfg"
        }
    }
}

Get-ChildItem -LiteralPath $Root -Filter '*.xci' -Recurse | ForEach-Object {
    try {
        Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json | Out-Null
    } catch {
        Add-Failure "Invalid XCI JSON: $($_.FullName)"
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
