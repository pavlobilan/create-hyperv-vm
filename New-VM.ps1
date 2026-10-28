#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
    Creates a Hyper-V Generation 2 VM for a nested virtualization host.
.DESCRIPTION
    - 4 vCPU (or fewer if the host has fewer), static memory, Secure Boot disabled;
    - memory size, number of disks and their sizes are asked interactively;
    - disks are dynamic: <VMName>.vhdx (system), <VMName>-Data.vhdx, <VMName>-Data2.vhdx, ...;
    - VM config: <RootPath>\<VMName>\Virtual Machines
    - disks:     <RootPath>\<VMName>\Virtual Hard Disks
    - nested virtualization;
    - MAC address spoofing on request (off by default; needed for bridged nested VMs);
    - guest OS is shut down (not saved) when the host shuts down;
    - VM does not start automatically when the host starts;
    - static MAC address.
#>

$ErrorActionPreference = 'Stop'

# --- VM settings ---
$CpuCount        = 4
$DefaultMemoryGB = 8
$DefaultDisks    = 2
$DefaultSizesGB  = @(60, 200)   # defaults for disk 1, 2, ...
$ExtraDiskSizeGB = 100          # default for disks beyond the list above
$MaxDisks        = 16
$MaxDiskSizeGB   = 65536        # VHDX limit is 64 TB
$DefaultRoot     = 'D:\HyperV'

# Prompt with a pre-filled, editable default value (typed into the console input via SendKeys)
function Read-HostPrefilled {
    param([string]$Prompt, [string]$Default)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $keys = [regex]::Replace($Default, '[+^%~(){}\[\]]', '{$0}')
        [System.Windows.Forms.SendKeys]::SendWait($keys)
        $value = Read-Host $Prompt
    } catch {
        $value = Read-Host "$Prompt [$Default]"
    }
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
    $value
}

# Prompt for an integer in [Min, Max] with a default; repeats until the input is valid
function Read-Number {
    param([string]$Prompt, [int]$Default, [int]$Min, [int]$Max)
    while ($true) {
        $raw = (Read-Host "$Prompt [$Default]").Trim()
        if (-not $raw) { return $Default }
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge $Min -and $n -le $Max) { return $n }
        Write-Host "  Enter a whole number from $Min to $Max." -ForegroundColor Yellow
    }
}

# Yes/No prompt; Enter returns the default
function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false)
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $raw = (Read-Host "$Prompt [$hint]").Trim().ToLower()
        if (-not $raw) { return $Default }
        if ($raw -in 'y', 'yes') { return $true }
        if ($raw -in 'n', 'no')  { return $false }
        Write-Host '  Enter y or n.' -ForegroundColor Yellow
    }
}

try {
    # --- vCPU count (limited to the host's logical processors) ---
    $HostCpuCount = (Get-VMHost).LogicalProcessorCount
    if ($HostCpuCount -lt $CpuCount) {
        Write-Host ("Host has only {0} logical processor(s); vCPU count reduced from {1} to {0}." -f $HostCpuCount, $CpuCount) -ForegroundColor Yellow
        $CpuCount = $HostCpuCount
    }

    # --- VM name ---
    $VMName = (Read-Host 'VM name [VM01]').Trim()
    if ([string]::IsNullOrWhiteSpace($VMName)) { $VMName = 'VM01' }
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        throw "VM '$VMName' already exists."
    }

    # --- Folder where VMs are stored (a <VMName> subfolder is created in it) ---
    $RootPath = (Read-HostPrefilled 'Folder for virtual machines' $DefaultRoot).Trim().Trim('"').TrimEnd('\')
    if (-not [System.IO.Path]::IsPathRooted($RootPath)) {
        throw 'Specify a full path, e.g. D:\HyperV'
    }
    $Qualifier = [System.IO.Path]::GetPathRoot($RootPath)
    if (-not (Test-Path -LiteralPath $Qualifier)) {
        throw "Drive or share '$Qualifier' not found."
    }

    $VMFolder = Join-Path $RootPath $VMName
    $DiskPath = Join-Path $VMFolder 'Virtual Hard Disks'
    if (Test-Path -LiteralPath $VMFolder) { throw "Folder '$VMFolder' already exists." }

    # --- Memory (static, limited to the host's physical memory) ---
    $HostMemGB = [math]::Floor((Get-VMHost).MemoryCapacity / 1GB)
    $FreeMemGB = [math]::Floor((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB / 1GB)
    $MemoryGB  = Read-Number "Memory, GB (host: $HostMemGB GB, free: $FreeMemGB GB)" ([math]::Min($DefaultMemoryGB, $HostMemGB)) 1 $HostMemGB
    if ($MemoryGB -gt $FreeMemGB) {
        Write-Host "  Warning: only $FreeMemGB GB is free now; the VM may fail to start." -ForegroundColor Yellow
    }
    $MemoryBytes = [int64]$MemoryGB * 1GB

    # --- Disks ---
    $DiskCount = Read-Number 'Number of disks' $DefaultDisks 1 $MaxDisks
    $Disks = for ($i = 1; $i -le $DiskCount; $i++) {
        $name = switch ($i) { 1 { "$VMName.vhdx" } 2 { "$VMName-Data.vhdx" } default { "$VMName-Data$($i - 1).vhdx" } }
        $def  = if ($i -le $DefaultSizesGB.Count) { $DefaultSizesGB[$i - 1] } else { $ExtraDiskSizeGB }
        $size = Read-Number "  Disk $i ($name) size, GB" $def 1 $MaxDiskSizeGB
        [pscustomobject]@{ Path = [System.IO.Path]::Combine($DiskPath, $name); SizeBytes = [int64]$size * 1GB }
    }
    $Disks = @($Disks)

    # --- Virtual switch ---
    $Switches = @(Get-VMSwitch)
    $SwitchName = $null
    if ($Switches.Count -gt 0) {
        Write-Host 'Available virtual switches:'
        for ($i = 0; $i -lt $Switches.Count; $i++) {
            Write-Host ("  [{0}] {1} ({2})" -f ($i + 1), $Switches[$i].Name, $Switches[$i].SwitchType)
        }
        $choice = (Read-Host 'Switch number (Enter = do not connect)').Trim()
        if ($choice) {
            $idx = [int]$choice - 1
            if ($idx -lt 0 -or $idx -ge $Switches.Count) { throw 'Invalid switch number.' }
            $SwitchName = $Switches[$idx].Name
        }
    }

    # --- MAC address spoofing (needed when nested VMs are bridged to the network) ---
    $MacSpoofing = Read-YesNo 'Enable MAC address spoofing (for bridged nested VMs)?' $false

    # --- ISO image (optional) ---
    $IsoPath = (Read-Host 'Path to ISO (Enter = skip)').Trim().Trim('"')
    if ($IsoPath -and -not (Test-Path $IsoPath)) { throw "ISO '$IsoPath' not found." }

    # --- Create disks ---
    New-Item -ItemType Directory -Path $DiskPath -Force | Out-Null
    foreach ($d in $Disks) { New-VHD -Path $d.Path -SizeBytes $d.SizeBytes -Dynamic | Out-Null }

    # --- Create VM (New-VM stores its config in <RootPath>\<VMName>\Virtual Machines) ---
    $vmParams = @{
        Name               = $VMName
        Generation         = 2
        MemoryStartupBytes = $MemoryBytes
        Path               = $RootPath
        VHDPath            = $Disks[0].Path
    }
    if ($SwitchName) { $vmParams.SwitchName = $SwitchName }
    New-VM @vmParams | Out-Null

    # Static memory (required for nested virtualization)
    Set-VM -Name $VMName -StaticMemory -MemoryStartupBytes $MemoryBytes

    # Shut down the guest OS instead of saving its state when the host shuts down
    Set-VM -Name $VMName -AutomaticStopAction ShutDown

    # Do not start the VM automatically when the host starts
    Set-VM -Name $VMName -AutomaticStartAction Nothing

    # Shutdown integration service (matched by GUID, since its name depends on the Windows language)
    Get-VMIntegrationService -VMName $VMName |
        Where-Object { $_.Id -match '9F8233AC-BE49-4C79-8EE3-E7E1985B2077' } |
        Enable-VMIntegrationService

    # Processors and nested virtualization
    Set-VMProcessor -VMName $VMName -Count $CpuCount -ExposeVirtualizationExtensions $true

    # Data disks
    $Disks | Select-Object -Skip 1 | ForEach-Object { Add-VMHardDiskDrive -VMName $VMName -Path $_.Path }

    # Allow the VM to forward packets with foreign MAC addresses (only if requested)
    Set-VMNetworkAdapter -VMName $VMName -MacAddressSpoofing $(if ($MacSpoofing) { 'On' } else { 'Off' })

    # Static MAC address in the Hyper-V range 00-15-5D, unique among VMs on this host
    $UsedMacs = @(Get-VM | Get-VMNetworkAdapter | ForEach-Object { $_.MacAddress })
    do {
        $StaticMac = '00155D' + (-join (1..3 | ForEach-Object { '{0:X2}' -f (Get-Random -Maximum 256) }))
    } while ($UsedMacs -contains $StaticMac)
    Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress $StaticMac

    # Disable Secure Boot
    Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

    # Attach ISO and boot from it first
    if ($IsoPath) {
        $dvd = Add-VMDvdDrive -VMName $VMName -Path $IsoPath -Passthru
        Set-VMFirmware -VMName $VMName -FirstBootDevice $dvd
    }

    # --- Summary ---
    $vm = Get-VM -Name $VMName
    Write-Host ''
    Write-Host "VM '$VMName' created." -ForegroundColor Green
    Write-Host ''
    Write-Host ("  VM folder:         {0}" -f $vm.Path)
    Write-Host ("  vCPU:              {0}" -f (Get-VMProcessor -VMName $VMName).Count)
    Write-Host ("  Memory:            {0} GB (static)" -f ($vm.MemoryStartup / 1GB))
    Write-Host ("  Secure Boot:       {0}" -f (Get-VMFirmware -VMName $VMName).SecureBoot)
    Write-Host ("  Host start action: {0}" -f $vm.AutomaticStartAction)
    Write-Host ("  Host stop action:  {0}" -f $vm.AutomaticStopAction)
    Write-Host ("  MAC address:       {0} (static)" -f (($StaticMac -split '(..)' -ne '') -join '-'))
    Write-Host ("  MAC spoofing:      {0}" -f (Get-VMNetworkAdapter -VMName $VMName).MacAddressSpoofing)
    Write-Host ("  Switch:            {0}" -f ($(if ($SwitchName) { $SwitchName } else { 'not connected' })))
    Get-VMHardDiskDrive -VMName $VMName | ForEach-Object {
        $v = Get-VHD -Path $_.Path
        Write-Host ("  Disk:              {0} ({1} GB, {2})" -f $v.Path, ($v.Size / 1GB), $v.VhdType)
    }
}
catch {
    Write-Host ''
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'VM was not created or was created only partially; check Hyper-V Manager.' -ForegroundColor Yellow
}
finally {
    Write-Host ''
    # Read-Host always appends ': ' to its prompt, so the text is printed separately
    Write-Host 'Press Enter to exit...' -NoNewline
    Read-Host | Out-Null
}
