# 🔧 PowerShell IT Toolkit

Scripts I've built and refined over 8+ years managing Windows environments — aviation, healthcare, childcare, enterprise. Most of these started as one-offs I kept rewriting from scratch until I got tired of that and turned them into proper reusable tools.

If you're an IT admin managing Windows at scale (or even at smaller scale and you're just tired of doing things manually), there's probably something useful here.

## 📦 Scripts

| Script | What it does |
|---|---|
| `Cleanup-PC.ps1` | Full PC cleanup: temp files, browser cache, Windows Update cache, old profiles |
| `New-UserOnboarding.ps1` | AD account creation, M365 license assignment, group memberships — one run |
| `Get-SystemHealth.ps1` | Quick health check: disk, memory, services, pending updates |
| `Export-ADReport.ps1` | Stale accounts, group memberships, password expiry — exported to CSV |
| `Set-IntunePolicy.ps1` | Bulk Intune policy deployment and compliance check |
| `Sync-M365Groups.ps1` | M365 group sync and license management |
| `Install-Baseline.ps1` | Standard software deployment for new workstations |
| `Test-NetworkDiag.ps1` | DNS resolution, connectivity, latency, proxy detection |

## 🚀 Quick Start

```powershell
# Clone the repo
git clone https://github.com/bastiaan365/powershell-it-toolkit.git

# Always run cleanup in dry-run first
.\scripts\Cleanup-PC.ps1 -DryRun

# Then for real
.\scripts\Cleanup-PC.ps1 -Verbose

# Generate AD report
.\scripts\Export-ADReport.ps1 -OutputPath .\reports\
```

## 📋 Requirements

- PowerShell 5.1+ (Windows) or PowerShell 7+ (cross-platform scripts)
- Admin rights where noted
- For M365 scripts: Microsoft Graph PowerShell SDK (`Install-Module Microsoft.Graph`)
- For AD scripts: RSAT ActiveDirectory module

## ⚙️ Configuration

Copy `config/settings.example.json` to `config/settings.json` and update:

- Organization name and domain
- M365 tenant ID
- Default OU paths
- Software deployment list
- Log file locations

## Why these scripts?

The cleanup script came from a real problem: endpoints at KLM were filling up on temp files because users never rebooted. The health check script is what I ran before touching any machine — gives a 30-second picture of what state it's in. The AD report was something managers asked for every quarter; this made that a 2-minute job instead of an afternoon.

They're all generalized from production versions — org-specific OUs, tenant IDs, and software lists have been replaced with configurable values. Test everything in a non-production environment before running on live systems.

## 📁 Structure

```
├── scripts/          # Individual PowerShell scripts
├── modules/
│   └── ITToolkit.psm1    # Shared helper module
├── config/
│   └── settings.example.json
└── docs/
    └── usage-guide.md
```

## 🔗 Related

- [bastiaan365.com](https://bastiaan365.com) — my IT portfolio
- [homelab-infrastructure](https://github.com/bastiaan365/homelab-infrastructure) — the network this toolkit manages

## Contributing

Pull requests welcome. If you've got a script that solves a common Windows IT problem I haven't covered, open an issue first so we can discuss scope before you build it out.
