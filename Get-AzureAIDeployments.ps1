# Azure AI Deployments Scanner with Retirement Data
# Scans all Azure OpenAI and Foundry model deployments across subscriptions
# Includes model retirement dates and replacement information
# Created for Azure AI deployment lifecycle management
# Version: 2.0 with Disclaimer

param(
    [string]$ModelFilter = "",
    [string]$SubscriptionId = "",
    [ValidateSet("CSV", "Excel")]
    [string]$OutputFormat = "Excel",
    [switch]$All,
    [switch]$CurrentSubscriptionOnly,
    [switch]$NoRetirementData,
    [switch]$Help
)

# Show help if requested
if ($Help) {
    @"
Azure AI Deployments Scanner with Retirement Data
=================================================

Scans Azure OpenAI and Foundry model deployments and includes retirement information.

USAGE:
  .\Get-AzureAIDeployments.ps1 [OPTIONS]

OPTIONS:
  -All                       List all deployments (no filtering)
  -ModelFilter <string>      Filter by model name (e.g., "gpt-4o")
  -SubscriptionId <id>       Scan specific subscription only
  -CurrentSubscriptionOnly   Scan only current subscription (default scans all accessible)
  -OutputFormat <format>     Output format: CSV or Excel (default)
  -NoRetirementData          Exclude retirement date and replacement model columns (original format)
  -Help                      Show this help message

EXAMPLES:
  .\Get-AzureAIDeployments.ps1 -All
  .\Get-AzureAIDeployments.ps1 -ModelFilter "gpt-4o"
  .\Get-AzureAIDeployments.ps1 -All -SubscriptionId "xxx-xxx-xxx"
  .\Get-AzureAIDeployments.ps1 -CurrentSubscriptionOnly -All
  .\Get-AzureAIDeployments.ps1 -CurrentSubscriptionOnly -ModelFilter "gpt-4o"
  .\Get-AzureAIDeployments.ps1 -All -OutputFormat Excel
  .\Get-AzureAIDeployments.ps1 -All -OutputFormat CSV
  .\Get-AzureAIDeployments.ps1 -All -NoRetirementData

OUTPUT:
  Results include retirement dates and replacement model information (unless -NoRetirementData is used).
  Results are displayed on screen and saved to file (format based on -OutputFormat parameter)
  Excel format requires ImportExcel PowerShell module

"@
    exit 0
}

# Function to extract retirement data
function Get-RetirementData {
    Write-Host "Fetching latest model retirement data from Microsoft Azure AI docs..." -ForegroundColor Cyan
    
    # GitHub raw content URL
    $githubUrl = "https://raw.githubusercontent.com/MicrosoftDocs/azure-ai-docs/main/articles/ai-foundry/openai/includes/retirement/models.md"
    
    try {
        # Download the markdown content
        $response = Invoke-WebRequest -Uri $githubUrl -UseBasicParsing
        $content = $response.Content
        Write-Host "✓ Successfully downloaded model retirement data" -ForegroundColor Green
    } catch {
        Write-Host "⚠ WARNING: Failed to download retirement data: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "⚠ WARNING: Continuing without retirement information. Output will not include RetirementDate and ReplacementModel columns." -ForegroundColor Yellow
        Write-Host ""
        return @()
    }
    
    # Split content into lines for processing
    $lines = $content -split "`n"
    
    $allModels = @()
    $currentSection = ""
    $inTable = $false
    $tableHeaders = @()
    
    # Process each line
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        
        # Detect section headers
        if ($line -match "^###?\s*(Text generation|Audio|Image and video|Embedding)") {
            $currentSection = $matches[1]
            $inTable = $false
            continue
        }
        
        # Detect table headers (lines with | Model | Version | etc.)
        if ($line -match "^\|\s*Model" -and $currentSection) {
            $tableHeaders = $line -split '\|' | Where-Object { $_.Trim() -ne "" } | ForEach-Object { $_.Trim() }
            $inTable = $true
            # Skip the separator line (usually next line with |---|---|)
            $i++
            continue
        }
        
        # Process table data rows
        if ($inTable -and $line -match "^\|" -and $line -notmatch "^\|\s*-+\s*\|" -and $currentSection) {
            $cells = $line -split '\|' | Where-Object { $_.Trim() -ne "" } | ForEach-Object { $_.Trim() }
            
            if ($cells.Count -ge 3) {  # Ensure we have at least model, version, and one more column
                # Map the model type
                $modelType = switch ($currentSection) {
                    "Text generation" { "Text Generation" }
                    "Audio" { "Audio" }
                    "Image and video" { "Image/Video" }
                    "Embedding" { "Embedding" }
                    default { $currentSection }
                }
                
                # Clean function to remove backticks and extra whitespace
                function Clean-Text($text) {
                    if (-not $text) { return "" }
                    return $text.Trim() -replace '`', ''
                }
                
                # Create model object with standardized properties
                $model = [PSCustomObject]@{
                    ModelType = $modelType
                    ModelName = Clean-Text $cells[0]
                    Version = Clean-Text $cells[1]
                    LifecycleStage = Clean-Text $cells[2]
                    DeprecationDate = if ($cells.Count -gt 3) { Clean-Text $cells[3] } else { "" }
                    RetirementDate = if ($cells.Count -gt 4) { Clean-Text $cells[4] } else { "" }
                    ReplacementModel = if ($cells.Count -gt 5) { Clean-Text $cells[5] } else { "" }
                }
                
                $allModels += $model
            }
        }
        
        # Exit table when we hit a new section or paragraph
        if ($inTable -and ($line -eq "" -or ($line -match "^#" -and $line -notmatch "^###"))) {
            $inTable = $false
        }
    }
    
    Write-Host "✓ Parsed $($allModels.Count) retirement records" -ForegroundColor Green
    return $allModels
}

# Function to join deployment data with retirement data
function Join-DeploymentWithRetirement {
    param(
        [Parameter(Mandatory)]
        $Deployments,
        [Parameter(Mandatory)]
        $RetirementData
    )
    
    Write-Host "Joining deployment data with retirement information..." -ForegroundColor Cyan
    
    $joinedDeployments = @()
    
    foreach ($deployment in $Deployments) {
        # Find matching retirement record (take first match only to avoid arrays)
        $retirementRecord = $RetirementData | Where-Object { 
            $_.ModelName -eq $deployment.Model -and $_.Version -eq $deployment.Version
        } | Select-Object -First 1
        
        # Helper function to safely convert to string (handles arrays and empty values)
        function Convert-ToSafeString($value) {
            if (-not $value) { return "N/A" }
            if ($value -is [Array]) {
                $nonEmptyValues = $value | Where-Object { $_ -and $_.ToString().Trim() -ne "" }
                if ($nonEmptyValues) {
                    return ($nonEmptyValues -join "; ").Trim()
                } else {
                    return "N/A"
                }
            }
            return $value.ToString().Trim()
        }
        
        # Create new deployment object with retirement data
        $joinedDeployment = [PSCustomObject]@{
            SubscriptionId = $deployment.SubscriptionId
            SubscriptionName = $deployment.SubscriptionName
            ResourceGroup = $deployment.ResourceGroup
            Resource = $deployment.Resource
            Deployment = $deployment.Deployment
            Model = $deployment.Model
            Version = $deployment.Version
            Status = $deployment.Status
            Sku = $deployment.Sku
            Capacity = $deployment.Capacity
            Endpoint = $deployment.Endpoint
            Location = $deployment.Location
            CreatedDate = $deployment.CreatedDate
            VersionUpgradeOption = $deployment.VersionUpgradeOption
            RetirementDate = if ($retirementRecord) { Convert-ToSafeString $retirementRecord.RetirementDate } else { "N/A" }
            ReplacementModel = if ($retirementRecord) { Convert-ToSafeString $retirementRecord.ReplacementModel } else { "N/A" }
        }
        
        $joinedDeployments += $joinedDeployment
    }
    
    Write-Host "✓ Joined $($joinedDeployments.Count) deployment records with retirement data" -ForegroundColor Green
    return $joinedDeployments
}

# Prerequisites check
Write-Host "Azure AI Deployments Scanner with Retirement Data v2.0" -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green
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

# Get retirement data first (unless explicitly disabled)
if ($NoRetirementData) {
    Write-Host "Retirement data disabled via -NoRetirementData parameter" -ForegroundColor Yellow
    $retirementData = @()
    $hasRetirementData = $false
} else {
    $retirementData = Get-RetirementData
    $hasRetirementData = ($retirementData.Count -gt 0)
}

if ($hasRetirementData -and -not $NoRetirementData) {
    Write-Host "✓ Retirement data available - will include RetirementDate and ReplacementModel columns" -ForegroundColor Green
} elseif ($NoRetirementData) {
    Write-Host "✓ Running in basic mode - retirement data columns excluded by user choice" -ForegroundColor Green
} else {
    Write-Host "⚠ No retirement data available - output will match original format" -ForegroundColor Yellow
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
                        # Create base deployment object (same structure regardless of retirement data option)
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

# Join deployment data with retirement data if available and not disabled
If ($allDeployments.Count -gt 0 -and $hasRetirementData -and -not $NoRetirementData) {
    $allDeployments = Join-DeploymentWithRetirement -Deployments $allDeployments -RetirementData $retirementData
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
        $timestampedFile = "deployments-results-v2-$timestamp.xlsx"
        
        # Export to Excel with formatting (start data after disclaimer)
        $excelParams = @{
            AutoSize = $true
            AutoFilter = $true
            FreezeTopRow = $true
            BoldTopRow = $true
            WorksheetName = "Azure AI Deployments"
            TableStyle = "Medium2"
            StartRow = 4  # Start data after disclaimer
        }
        
        # Add disclaimer to Excel
        $disclaimerText = "DISCLAIMER: This script is NOT an official Microsoft solution and is not supported under any Microsoft support program. Use at your own discretion."
        
        $filteredDeployments | Export-Excel -Path $timestampedFile @excelParams
        
        # Add disclaimer at the top of the worksheet
        $excel = Open-ExcelPackage -Path $timestampedFile
        $worksheet = $excel.Workbook.Worksheets["Azure AI Deployments"]
        $worksheet.Cells["A1"].Value = $disclaimerText
        $worksheet.Cells["A1"].Style.Font.Bold = $true
        $worksheet.Cells["A1"].Style.Font.Color.SetColor([System.Drawing.Color]::Red)
        $worksheet.Cells["A1:E1"].Merge = $true
        $worksheet.Cells["A1"].Style.WrapText = $true
        Close-ExcelPackage $excel
        
        Write-Host "Results saved to:" -ForegroundColor Green
        Write-Host "  - $timestampedFile" -ForegroundColor White
    } else {
        $timestampedFile = "deployments-results-v2-$timestamp.csv"
        
        # Add disclaimer to CSV file
        $disclaimer = @(
            "# DISCLAIMER: This script is NOT an official Microsoft solution and is not supported under any Microsoft support program.",
            "# Use at your own discretion.",
            "#"
        )
        
        # Write disclaimer first
        $disclaimer | Out-File -FilePath $timestampedFile -Encoding UTF8
        
        # Export to CSV and append to file
        $filteredDeployments | Export-Csv -Path $timestampedFile -NoTypeInformation -Append
        
        Write-Host "Results saved to:" -ForegroundColor Green
        Write-Host "  - $timestampedFile" -ForegroundColor White
    }
    
    # Summary
    Write-Host ""
    Write-Host "SUMMARY:" -ForegroundColor Cyan
    Write-Host "Total deployments: $($filteredDeployments.Count)" -ForegroundColor White
    
    # Retirement status summary (only if retirement data is available and not disabled)
    if ($hasRetirementData -and -not $NoRetirementData) {
        $retiringModels = $filteredDeployments | Where-Object { $_.RetirementDate -ne "N/A" -and $_.RetirementDate.Trim() -ne "" }
        if ($retiringModels.Count -gt 0) {
            Write-Host "Models with retirement dates: $($retiringModels.Count)" -ForegroundColor Yellow
        }
    }
    
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
Write-Host "DISCLAIMER:" -ForegroundColor Yellow
Write-Host "This script is NOT an official Microsoft solution and is not supported under any Microsoft support program." -ForegroundColor Yellow
Write-Host "Use at your own discretion." -ForegroundColor Yellow

Write-Host ""
Write-Host "For detailed retirement schedules, please visit: https://learn.microsoft.com/en-us/azure/ai-foundry/openai/concepts/model-retirements" -ForegroundColor Cyan