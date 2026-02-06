# Azure AI Deployments Scanner
# Scans all Azure OpenAI and Foundry model deployments across subscriptions
# Created for Azure AI deployment lifecycle management
# Version: 1.0

param(
    [string]$ModelFilter = "",
    [string]$SubscriptionId = "",
    [ValidateSet("CSV", "Excel")]
    [string]$OutputFormat = "Excel",
    [switch]$All,
    [switch]$CurrentSubscriptionOnly,
    [switch]$Help
)

# Show help if requested
if ($Help) {
    @"
Azure AI Deployments Scanner
============================

Scans Azure OpenAI and Foundry model deployments for model deployments.

USAGE:
  .\Get-AzureAIDeployments.ps1 [OPTIONS]

OPTIONS:
  -All                       List all deployments (no filtering)
  -ModelFilter <string>      Filter by model name (e.g., "gpt-4o")
  -SubscriptionId <id>       Scan specific subscription only
  -CurrentSubscriptionOnly   Scan only current subscription (default scans all accessible)
  -OutputFormat <format>     Output format: CSV (default) or Excel
  -Help                      Show this help message

EXAMPLES:
  .\Get-AzureAIDeployments.ps1 -All
  .\Get-AzureAIDeployments.ps1 -ModelFilter "gpt-4o"
  .\Get-AzureAIDeployments.ps1 -All -SubscriptionId "xxx-xxx-xxx"
  .\Get-AzureAIDeployments.ps1 -CurrentSubscriptionOnly -All
  .\Get-AzureAIDeployments.ps1 -CurrentSubscriptionOnly -ModelFilter "gpt-4o"
  .\Get-AzureAIDeployments.ps1 -All -OutputFormat Excel
  .\Get-AzureAIDeployments.ps1 -All -OutputFormat CSV
  .\Get-AzureAIDeployments.ps1 -ModelFilter "gpt-4o" -OutputFormat Excel

OUTPUT:
  Results are displayed on screen and saved to file (format based on -OutputFormat parameter)
  Excel format requires ImportExcel PowerShell module

"@
    exit 0
}

# Prerequisites check
Write-Host "Azure AI Deployments Scanner v1.0" -ForegroundColor Green
Write-Host "===================================" -ForegroundColor Green
Write-Host ""

# Check if Azure CLI is installed
try {
    $azVersion = az --version 2>$null
    if (-not $azVersion) { throw "Azure CLI not found" }
    Write-Host "✓ Azure CLI found" -ForegroundColor Green

    # Check for ImportExcel module if Excel output is requested
    if ($OutputFormat -eq "Excel") {
        try {
            Import-Module ImportExcel -ErrorAction Stop
            Write-Host "✓ ImportExcel PowerShell module found" -ForegroundColor Green
        }
        catch {
            Write-Host "⚠ ImportExcel PowerShell module not found. Installing..." -ForegroundColor Yellow
            try {
                Install-Module ImportExcel -Force -AllowClobber -Scope CurrentUser
                Import-Module ImportExcel
                Write-Host "✓ ImportExcel PowerShell module installed successfully" -ForegroundColor Green
            }
            catch {
                Write-Host "✗ Failed to install ImportExcel module. Falling back to CSV format." -ForegroundColor Red
                $OutputFormat = "CSV"
            }
        }
    }
} catch {
    Write-Host "Azure CLI not found" -ForegroundColor Red
    Write-Host "Please install Azure CLI from: https://aka.ms/installazurecliwindows" -ForegroundColor Yellow
    exit 1
}

# Check if user is logged in
try {
    $account = az account show --query "user.name" -o tsv 2>$null
    if (-not $account) { throw "Not logged in" }
    Write-Host "Logged in as: $account" -ForegroundColor Green
} catch {
    Write-Host "Not logged in to Azure" -ForegroundColor Red
    Write-Host "Please run: az login" -ForegroundColor Yellow
    exit 1
}

Write-Host ""

$allDeployments = @()
$processedCount = 0
$totalResources = 0

# Determine which subscriptions to scan
if ($SubscriptionId) {
    # Specific subscription requested
    $subscriptions = @([PSCustomObject]@{id = $SubscriptionId; name = "Specified Subscription"})
    Write-Host "Scanning specified subscription: $SubscriptionId" -ForegroundColor Cyan
} elseif ($CurrentSubscriptionOnly) {
    # Current subscription only
    $currentSubscriptionId = az account show --query "id" -o tsv
    $currentSubscriptionName = az account show --query "name" -o tsv
    $subscriptions = @([PSCustomObject]@{id = $currentSubscriptionId; name = $currentSubscriptionName})
    Write-Host "Scanning current subscription only: $currentSubscriptionName ($currentSubscriptionId)" -ForegroundColor Cyan
} else {
    # Default: scan all accessible subscriptions
    Write-Host "Getting all accessible subscriptions..." -ForegroundColor Cyan
    $subscriptions = az account list --query "[?state=='Enabled'].{id:id, name:name}" --output json | ConvertFrom-Json
    Write-Host "Found $($subscriptions.Count) accessible subscription(s)" -ForegroundColor Green
    Write-Host "Options: Use -CurrentSubscriptionOnly for current subscription only, or -SubscriptionId <id> for specific subscription" -ForegroundColor Gray
    Write-Host ""
}

Write-Host ""

# Scan each subscription
foreach ($subscription in $subscriptions) {
    if ($subscriptions.Count -gt 1) {
        Write-Host "=== SUBSCRIPTION: $($subscription.name) ($($subscription.id)) ===" -ForegroundColor Magenta
    }
    
    # Get all AI Services and OpenAI resources for this subscription
    $resources = az cognitiveservices account list --subscription $subscription.id --output json | ConvertFrom-Json | Where-Object { $_.kind -eq 'AIServices' -or $_.kind -eq 'OpenAI' } | Select-Object name, resourceGroup, @{Name='endpoint'; Expression={$_.properties.endpoint}}, @{Name='subscriptionId'; Expression={$subscription.id}}, @{Name='subscriptionName'; Expression={$subscription.name}}
    
    if (-not $resources -or $resources.Count -eq 0) {
        Write-Host "No AI Services resources found in this subscription." -ForegroundColor Yellow
        if ($subscriptions.Count -gt 1) {
            Write-Host ""
        }
        continue
    }
    
    $totalResources += $resources.Count
    Write-Host "Found $($resources.Count) AI resources in this subscription..." -ForegroundColor Green
    Write-Host ""
    
    foreach ($resource in $resources) {
        $processedCount++
        Write-Host "[$processedCount/$totalResources] Scanning: $($resource.name)" -ForegroundColor Yellow
        
        try {
            # Try to get deployments (this works for both OpenAI and AI Services)
            $deploymentCommand = "az cognitiveservices account deployment list --name '$($resource.name)' --resource-group '$($resource.resourceGroup)' --subscription '$($resource.subscriptionId)' --output json 2>`$null"
            
            $deploymentsJson = Invoke-Expression $deploymentCommand
            
            if ($deploymentsJson) {
                $deployments = $deploymentsJson | ConvertFrom-Json
                
                if ($deployments -and $deployments.Count -gt 0) {
                    Write-Host "  -> Found $($deployments.Count) deployment(s)" -ForegroundColor Green
                    
                    foreach ($deployment in $deployments) {
                        $allDeployments += [PSCustomObject]@{
                            SubscriptionId = $resource.subscriptionId
                            SubscriptionName = $resource.subscriptionName
                            ResourceGroup = $resource.resourceGroup
                            Resource = $resource.name
                            Deployment = $deployment.name
                            Model = $deployment.properties.model.name
                            Version = $deployment.properties.model.version
                            Status = $deployment.properties.provisioningState
                            Sku = $deployment.sku.name
                            Capacity = $deployment.sku.capacity
                            Endpoint = $resource.endpoint
                            Location = $deployment.properties.model.format
                            CreatedDate = $deployment.systemData.createdAt
                            VersionUpgradeOption = if ($deployment.properties.versionUpgradeOption) { $deployment.properties.versionUpgradeOption } else { "N/A" }
                            # RetirementDate not available through Azure CLI API
                            # Check Microsoft documentation for model retirement announcements
                        }
                    }
                } else {
                    Write-Host "  -> No deployments" -ForegroundColor Gray
                }
            }
        } catch {
            Write-Host "  -> Error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    if ($subscriptions.Count -gt 1) {
        Write-Host ""
    }
}

# Check if we found any resources across all subscriptions
if ($totalResources -eq 0) {
    Write-Host "No AI Services resources found in any accessible subscription." -ForegroundColor Red
    Write-Host "Make sure you have access to Azure OpenAI or AI Services resources." -ForegroundColor Yellow
    exit 0
}

# Apply filter if specified
if (-not $All -and $ModelFilter -and $ModelFilter.Trim() -ne "") {
    Write-Host ""
    Write-Host "Filtering by model: $ModelFilter" -ForegroundColor Cyan
    $filteredDeployments = $allDeployments | Where-Object { $_.Model -like "*$ModelFilter*" }
} else {
    # Show all deployments (either -All was specified or no specific filter was provided)
    if (-not $All -and (-not $ModelFilter -or $ModelFilter.Trim() -eq "")) {
        Write-Host ""
        Write-Host "Showing all deployments (use -ModelFilter to filter or -Help for options)" -ForegroundColor Cyan
    }
    $filteredDeployments = $allDeployments
}

Write-Host ""
Write-Host "RESULTS:" -ForegroundColor Green
Write-Host "========" -ForegroundColor Green

if ($filteredDeployments.Count -eq 0) {
    Write-Host "No deployments found." -ForegroundColor Red
} else {
    # Display results
    $filteredDeployments | Format-Table -AutoSize
    
    # Save results based on output format
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    
    if ($OutputFormat -eq "Excel") {
        $timestampedFile = "deployments-results-$timestamp.xlsx"
        
        # Export to Excel with formatting
        $excelParams = @{
            AutoSize = $true
            AutoFilter = $true
            FreezeTopRow = $true
            BoldTopRow = $true
            WorksheetName = "Azure AI Deployments"
            TableStyle = "Medium2"
        }
        
        $filteredDeployments | Export-Excel -Path $timestampedFile @excelParams
        
        Write-Host "Results saved to:" -ForegroundColor Green
        Write-Host "  - $timestampedFile" -ForegroundColor White
    } else {
        $timestampedFile = "deployments-results-$timestamp.csv"
        
        # Export to CSV
        $filteredDeployments | Export-Csv -Path $timestampedFile -NoTypeInformation
        
        Write-Host "Results saved to:" -ForegroundColor Green
        Write-Host "  - $timestampedFile" -ForegroundColor White
    }
    
    # Summary
    Write-Host ""
    Write-Host "SUMMARY:" -ForegroundColor Cyan
    Write-Host "Total deployments: $($filteredDeployments.Count)" -ForegroundColor White
    
    # Subscription distribution (if multiple subscriptions were scanned)
    if ($subscriptions.Count -gt 1 -and $filteredDeployments.Count -gt 0) {
        $subscriptionGroups = $filteredDeployments | Group-Object SubscriptionName | Sort-Object Count -Descending
        Write-Host "Subscription distribution:" -ForegroundColor Cyan
        foreach ($group in $subscriptionGroups) {
            Write-Host "  $($group.Name): $($group.Count) deployment(s)" -ForegroundColor White
        }
    }
    
    # Model distribution
    $modelGroups = $filteredDeployments | Group-Object Model | Sort-Object Count -Descending
    Write-Host "Model distribution:" -ForegroundColor Cyan
    foreach ($group in $modelGroups) {
        Write-Host "  $($group.Name): $($group.Count) deployment(s)" -ForegroundColor White
    }
    
    # Resource distribution
    $resourceGroups = $filteredDeployments | Group-Object ResourceGroup | Sort-Object Count -Descending
    if ($resourceGroups.Count -gt 1) {
        Write-Host "Resource group distribution:" -ForegroundColor Cyan
        foreach ($group in $resourceGroups[0..4]) {  # Show top 5
            Write-Host "  $($group.Name): $($group.Count) deployment(s)" -ForegroundColor White
        }
    }
}

Write-Host ""
Write-Host "Scan completed!" -ForegroundColor Green
Write-Host "You can now download your deployments output file ($timestampedFile)." -ForegroundColor Green

Write-Host ""
Write-Host "For detailed retirement schedules, please visit: https://learn.microsoft.com/en-us/azure/ai-foundry/openai/concepts/model-retirements" -ForegroundColor Cyan