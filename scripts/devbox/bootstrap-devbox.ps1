<#
.SYNOPSIS
    Bootstrap an Azure Dev Box host with OpenSSH, Git, Docker Desktop, and workspace conventions.
.DESCRIPTION
    Use -PlanOnly to print the plan JSON and exit. Use -Apply to perform the bootstrap actions.
    Without either parameter, the script errors out.
#>
param(
    [switch]$PlanOnly,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

$plan = [ordered]@{
    workspaceRoot = 'C:\dev'
    features      = @('OpenSSH.Server~~~~0.0.1.0')
    packages      = @('Git.Git', 'Docker.DockerDesktop')
    sshdConfig    = @{
        AllowTcpForwarding = 'yes'
    }
    powerShellUtf8 = $true
}

if ($PlanOnly) {
    $plan | ConvertTo-Json -Depth 5
    exit 0
}

if (-not $Apply) {
    Write-Error "Specify -PlanOnly or -Apply"
    exit 1
}

function Invoke-WingetInstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    & winget install --id $PackageId --accept-source-agreements --accept-package-agreements --silent

    if ($LASTEXITCODE -ne 0) {
        throw "winget install failed for $PackageId with exit code $LASTEXITCODE"
    }
}

function Split-SshdConfigSections {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $firstMatchBlock = [regex]::Match($Content, '(?m)^(?!\s*#)\s*Match(?:\s|$)')

    if ($firstMatchBlock.Success) {
        return [pscustomobject]@{
            GlobalSection = $Content.Substring(0, $firstMatchBlock.Index)
            MatchBlocks   = $Content.Substring($firstMatchBlock.Index)
        }
    }

    return [pscustomobject]@{
        GlobalSection = $Content
        MatchBlocks   = ''
    }
}

function Get-EffectiveGlobalAllowTcpForwardingValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GlobalSection
    )

    foreach ($line in ($GlobalSection -split "\r?\n")) {
        if ($line -match '^\s*#') {
            continue
        }

        if ($line -match '^\s*AllowTcpForwarding\s+(\S+)') {
            return $Matches[1].ToLowerInvariant()
        }
    }

    # OpenSSH uses "yes" by default when the directive is absent.
    return 'yes'
}

# --- Apply path ---

# UTF-8-friendly PowerShell defaults (design: UTF-8-friendly PowerShell defaults)
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

# Install OpenSSH Server Windows capability
foreach ($featureName in $plan.features) {
    Add-WindowsCapability -Online -Name $featureName
}

# Set sshd to Automatic and start it
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd

# Ensure firewall allows SSH (port 22) - idempotent named rule
$sshFirewallRuleName = 'DevBox-OpenSSH-In-TCP'
if (-not (Get-NetFirewallRule -Name $sshFirewallRuleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name $sshFirewallRuleName -DisplayName 'OpenSSH Server (SSH) - Dev Box' -Enabled True -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow
}

# Ensure workspace root exists
$workspaceRoot = $plan.workspaceRoot
if (-not (Test-Path $workspaceRoot)) {
    New-Item -ItemType Directory -Path $workspaceRoot -Force | Out-Null
}

# Install required packages via winget
foreach ($packageId in $plan.packages) {
    Invoke-WingetInstall -PackageId $packageId
}

# Set AllowTcpForwarding in sshd_config (design: enabling AllowTcpForwarding for port forwarding)
$sshdConfigPath = "$env:ProgramData\ssh\sshd_config"
if (Test-Path $sshdConfigPath) {
    $allowTcpForwardingValue = $plan.sshdConfig.AllowTcpForwarding.ToLowerInvariant()
    $content = Get-Content $sshdConfigPath -Raw
    $sections = Split-SshdConfigSections -Content $content
    $currentAllowTcpForwardingValue = Get-EffectiveGlobalAllowTcpForwardingValue -GlobalSection $sections.GlobalSection

    if ($currentAllowTcpForwardingValue -ne $allowTcpForwardingValue) {
        $lineEnding = if ($content -match "`r`n") { "`r`n" } else { "`n" }
        $updatedGlobalSection = $sections.GlobalSection
        $directiveLine = "AllowTcpForwarding $allowTcpForwardingValue"
        $globalDirectiveMatch = [regex]::Match($updatedGlobalSection, '(?m)^(?!\s*#)\s*AllowTcpForwarding\s+.*$')

        if ($globalDirectiveMatch.Success) {
            $updatedGlobalSection =
                $updatedGlobalSection.Substring(0, $globalDirectiveMatch.Index) +
                $directiveLine +
                $updatedGlobalSection.Substring($globalDirectiveMatch.Index + $globalDirectiveMatch.Length)
        } else {
            if ([string]::IsNullOrEmpty($updatedGlobalSection)) {
                $updatedGlobalSection = $directiveLine + $lineEnding
            } elseif ($updatedGlobalSection -match '(\r?\n)$') {
                $updatedGlobalSection = $updatedGlobalSection + $directiveLine + $lineEnding
            } else {
                $updatedGlobalSection = $updatedGlobalSection + $lineEnding + $directiveLine + $lineEnding
            }
        }

        $updatedContent = $updatedGlobalSection + $sections.MatchBlocks

        if ($updatedContent -ne $content) {
            Set-Content -Path $sshdConfigPath -Value $updatedContent -Encoding UTF8
            Restart-Service sshd
        }
    }
}
