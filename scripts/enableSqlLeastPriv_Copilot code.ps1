<#
.SYNOPSIS
Enables SQL Arc extension feature flag "LeastPrivilege" on Arc machines where it is missing or not true.

.PREREQS
- Azure CLI installed and you are logged in: az login
- Azure CLI extensions:
  - resource-graph (for az graph query)  (auto-installs on first use)  https://learn.microsoft.com/cli/azure/graph [2](https://learn.microsoft.com/en-us/cli/azure/graph?view=azure-cli-latest)
  - arcdata (for az sql server-arc ...) (auto-installs on first use)  https://learn.microsoft.com/cli/azure/sql/server-arc/extension/feature-flag [1](https://learn.microsoft.com/en-us/cli/azure/sql/server-arc/extension/feature-flag?view=azure-cli-lts)
#>

[CmdletBinding()]
param(
    # If specified, this RG will be used for ALL machines (matches your example "myrg").
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup = "myrg",

    # If set, use each machine's discovered resourceGroup instead of the fixed $ResourceGroup.
    [Parameter(Mandatory = $false)]
    [switch]$UseDiscoveredResourceGroup,

    # Dry-run: show what would change but do not call the "set" command.
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    # Optional: scope Resource Graph to specific subscriptions (comma-separated list).
    [Parameter(Mandatory = $false)]
    [string[]]$Subscriptions
)

function Ensure-AzExtension {
    param([Parameter(Mandatory=$true)][string]$Name)

    $ext = az extension show --name $Name -o json 2>$null | ConvertFrom-Json
    if (-not $ext) {
        Write-Host "Installing Azure CLI extension '$Name'..." -ForegroundColor Yellow
        az extension add --name $Name -o none | Out-Null
    } else {
        # Optional: keep updated
        az extension update --name $Name -o none 2>$null | Out-Null
    }
}

function Get-ArcSqlExtensionMachines {
    param([string[]]$Subscriptions)

    # KQL: find Arc machine extensions that match the SQL extension
    $kql = @"
Resources
| where type =~ 'microsoft.hybridcompute/machines/extensions'
| where tostring(properties.publisher) =~ 'Microsoft.AzureData'
| where tostring(properties.type) =~ 'WindowsAgent.SqlServer'
| extend segments = split(id, '/')
| extend machineName = tostring(segments[array_length(segments) - 3])
| project subscriptionId, resourceGroup, machineName
| distinct subscriptionId, resourceGroup, machineName
"@

    $all = @()
    $skipToken = $null

    do {
        $args = @("graph", "query", "-q", $kql, "--first", "1000", "-o", "json")
        if ($skipToken) { $args += @("--skip-token", $skipToken) }
        if ($Subscriptions -and $Subscriptions.Count -gt 0) { $args += @("--subscriptions") + $Subscriptions }

        $resp = az @args | ConvertFrom-Json
        if ($resp.data) { $all += $resp.data }
        $skipToken = $resp.skipToken
    } while ($skipToken)

    return $all
}

function Get-FeatureFlagEnabledState {
    param(
        [Parameter(Mandatory=$true)][string]$SubscriptionId,
        [Parameter(Mandatory=$true)][string]$ResourceGroup,
        [Parameter(Mandatory=$true)][string]$MachineName,
        [Parameter(Mandatory=$true)][string]$FlagName
    )

    # Try to query "enable" directly; if the flag doesn't exist, az returns non-zero.
    $enabled = $null
    try {
        $enabled = az sql server-arc extension feature-flag show `
            --name $FlagName `
            --resource-group $ResourceGroup `
            --machine-name $MachineName `
            --subscription $SubscriptionId `
            --query "enable" -o tsv 2>$null

        if ([string]::IsNullOrWhiteSpace($enabled)) { return $null }
        return $enabled.Trim()
    }
    catch {
        return $null
    }
}

# ---- main ----

# Ensure required CLI extensions
Ensure-AzExtension -Name "resource-graph"  # az graph query [2](https://learn.microsoft.com/en-us/cli/azure/graph?view=azure-cli-latest)
Ensure-AzExtension -Name "arcdata"         # az sql server-arc ... [1](https://learn.microsoft.com/en-us/cli/azure/sql/server-arc/extension/feature-flag?view=azure-cli-lts)

Write-Host "Discovering Arc machines with SQL extension (Microsoft.AzureData/WindowsAgent.SqlServer)..." -ForegroundColor Cyan
$machines = Get-ArcSqlExtensionMachines -Subscriptions $Subscriptions

if (-not $machines -or $machines.Count -eq 0) {
    Write-Host "No Arc machines found with the SQL extension." -ForegroundColor Yellow
    return
}

Write-Host "Found $($machines.Count) machine(s). Checking LeastPrivilege feature flag..." -ForegroundColor Cyan

$nonCompliant = @()

foreach ($m in $machines) {
    $subId = $m.subscriptionId
    $rgDiscovered = $m.resourceGroup
    $serverName = $m.machineName

    $rgToUse = if ($UseDiscoveredResourceGroup) { $rgDiscovered } else { $ResourceGroup }

    $state = Get-FeatureFlagEnabledState -SubscriptionId $subId -ResourceGroup $rgToUse -MachineName $serverName -FlagName "LeastPrivilege"

    $isCompliant = $false
    if ($state -ne $null -and $state.ToString().ToLowerInvariant() -eq "true") { $isCompliant = $true }

    if (-not $isCompliant) {
        $nonCompliant += [pscustomobject]@{
            SubscriptionId = $subId
            ResourceGroup  = $rgToUse
            MachineName    = $serverName
            LeastPrivilege = $state
            Action         = "Enable"
        }

        Write-Host "[$serverName] LeastPrivilege is missing or not true (current: '$state'). Enabling..." -ForegroundColor Yellow

        if (-not $WhatIf) {
            # Your requested command:
            az sql server-arc extension feature-flag set `
                --name LeastPrivilege `
                --enable true `
                --resource-group $rgToUse `
                --machine-name $serverName `
                --subscription $subId -o none
        } else {
            Write-Host "  WhatIf: would run az sql server-arc extension feature-flag set --name LeastPrivilege --enable true --resource-group $rgToUse --machine-name $serverName" -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host "[$serverName] LeastPrivilege = true (OK)" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Non-compliant machines: $($nonCompliant.Count)" -ForegroundColor Cyan
$nonCompliant | Sort-Object SubscriptionId, ResourceGroup, MachineName | Format-Table -AutoSize
``