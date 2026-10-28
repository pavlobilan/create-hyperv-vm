# create-hyperv-vm

PowerShell scripts for Windows administration.

## Quick start

Run PowerShell as Administrator. Download `New-VM.ps1` to a temporary file and run it (recommended, keeps the `#Requires` checks):

```powershell
$f = "$env:TEMP\New-VM.ps1"; try { irm "https://raw.githubusercontent.com/pavlobilan/create-hyperv-vm/main/New-VM.ps1" -OutFile $f -ErrorAction Stop; powershell -ExecutionPolicy Bypass -File $f } catch { $_ }
```

Or run without saving to disk:

```powershell
irm "https://raw.githubusercontent.com/pavlobilan/create-hyperv-vm/main/New-VM.ps1" | iex
```

To always run a reviewed version, replace `main` with a commit hash.

## New-VM.ps1

Interactively creates a Generation 2 Hyper-V virtual machine prepared to act as a host for nested VMs.

### What it configures

- vCPU: asked at runtime, from 1 to the host's logical processor count (default: the maximum)
- Memory: static, size asked at runtime (default 8 GB, limited to host memory)
- Disks: number and sizes asked at runtime (default 2 disks: 60 GB and 200 GB), all dynamic VHDX
- Secure Boot: disabled
- Nested virtualization: enabled
- MAC address spoofing: asked at runtime, off by default (enable it when nested VMs are bridged to the network)
- Static MAC address from the Hyper-V range `00-15-5D-xx-xx-xx`, unique among VMs on the host
- Automatic start action: Nothing
- Automatic stop action: Shut down (the Shutdown integration service is enabled)
- Optional ISO attached as the first boot device

### Folder layout

```text
<Folder>\<VMName>\
├── Virtual Machines\
└── Virtual Hard Disks\
    ├── <VMName>.vhdx
    ├── <VMName>-Data.vhdx
    └── <VMName>-Data2.vhdx ...
```

The folder is asked at runtime; the default (`D:\HyperV`) is pre-filled and can be edited.

### Requirements

- Windows with the Hyper-V role and the Hyper-V PowerShell module
- PowerShell run as Administrator

### Defaults

Edit the variables at the top of the script to change defaults:

| Variable | Default | Meaning |
|---|---|---|
| `$DefaultMemoryGB` | `8` | memory, GB |
| `$DefaultDisks` | `2` | number of disks |
| `$DefaultSizesGB` | `60, 200` | sizes of disk 1, 2, ..., GB |
| `$ExtraDiskSizeGB` | `100` | size of further disks, GB |
| `$DefaultRoot` | `D:\HyperV` | folder for virtual machines |

## License

MIT
