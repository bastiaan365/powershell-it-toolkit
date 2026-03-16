# 🔧 PowerShell IT Toolkit

Collection of PowerShell scripts built during 8+ years of Windows IT administration across aviation, healthcare and enterprise environments. Practical tools for daily IT operations.

## 📦 Scripts

| Script | Description |
|---|---|
| Cleanup-PC.ps1 | Full PC cleanup: temp files, browser cache, Windows Update cache, old profiles |
| New-UserOnboarding.ps1 | Automated user provisioning: AD account, M365 license, group memberships |
| Get-SystemHealth.ps1 | Quick system health check: disk, memory, services, updates |
| Export-ADReport.ps1 | Active Directory reporting: stale accounts, group memberships, password expiry |
| Set-IntunePolicy.ps1 | Bulk Intune policy deployment and compliance check |
| Sync-M365Groups.ps1 | Microsoft 365 group synchronization and license management |
| Install-Baseline.ps1 | Standard software deployment for new workstations |
| Test-NetworkDiag.ps1 | Network diagnostics: DNS, connectivity, latency, proxy detection |

## 🚀 Quick Start

```powershell
# Clone the repository
git clone https://github.com/bastiaan365/powershell-it-toolkit.git

# Run PC cleanup (requires admin)
.\scripts\Cleanup-PC.ps1 -DryRun
.\scripts\Cleanup-PC.ps1 -Verbose

# Generate AD report
.\scripts\Export-ADReport.ps1 -OutputPath .\reports\
```

## 📋 Requirements

- PowerShell 5.1+ (Windows) or PowerShell 7+ (cross-platform)
- Appropriate admin rights per script
- For M365 scripts: Microsoft Graph PowerShell SDK
- For AD scripts: ActiveDirectory module (RSAT)

## 📁 Structure

```
├── scripts/
│   ├── Cleanup-PC.ps1
│   ├── New-UserOnboarding.ps1
│   ├── Get-SystemHealth.ps1
│   ├── Export-ADReport.ps1
│   ├── Set-IntunePolicy.ps1
│   ├── Sync-M365Groups.ps1
│   ├── Install-Baseline.ps1
│   └── Test-NetworkDiag.ps1
├── modules/
│   └── ITToolkit.psm1
├── config/
│   └── settings.example.json
└── docs/
    └── usage-guide.md
```

## ⚙️ Configuration

Copy `config/settings.example.json` to `config/settings.json` and update:
- Organization name and domain
- M365 tenant ID
- Default OU paths
- Software deployment list
- Log file locations

## 🔗 Related

- [bastiaan365.com](https://bastiaan365.com) — My IT portfolio
- [LinkedIn](https://linkedin.com/in/bastiaanrusch)

---

*Scripts are generalized from real production tools. Org-specific details have been removed. Test in your environment before production use.*
