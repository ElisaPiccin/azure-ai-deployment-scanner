# Azure AI Deployments Scanner with Retirement Data
# Scans all Azure OpenAI and Foundry model deployments across subscriptions
# Includes model retirement dates and replacement information
# Created for Azure AI deployment lifecycle management
# Version: 3.0 with Azure Monitor Metrics integration

param(
    [string]$ModelFilter = "",
    [string]$SubscriptionId = "",
    [string]$ResourceGroupName = "",
    [ValidateSet("CSV", "Excel")]
    [string]$OutputFormat = "Excel",
    [switch]$All,
    [switch]$CurrentSubscriptionOnly,
    [switch]$NoRetirementData,
    [switch]$NoMetrics,
    [int]$DaysBack = 7,
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
  -ResourceGroupName <name>  Restrict scan to a specific resource group
  -CurrentSubscriptionOnly   Scan only current subscription (default scans all accessible)
  -OutputFormat <format>     Output format: CSV or Excel (default)
  -NoRetirementData          Exclude retirement date and replacement model columns (original format)
  -NoMetrics                 Exclude Azure Monitor metrics columns (TotalRequests, PromptTokens, GeneratedTokens)
  -DaysBack <int>            Number of days to look back for metrics (default: 7)
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
  .\Get-AzureAIDeployments.ps1 -All -NoMetrics
  .\Get-AzureAIDeployments.ps1 -All -DaysBack 30
  .\Get-AzureAIDeployments.ps1 -All -DaysBack 30
  .\Get-AzureAIDeployments.ps1 -All -ResourceGroupName "my-rg"
  .\Get-AzureAIDeployments.ps1 -CurrentSubscriptionOnly -ResourceGroupName "my-rg" -ModelFilter "gpt-4o"

OUTPUT:
  Results include retirement dates and replacement model information (unless -NoRetirementData is used).
  Results include Azure Monitor metrics: TotalRequests, PromptTokens, GeneratedTokens (unless -NoMetrics is used).
  Results are displayed on screen and saved to file (format based on -OutputFormat parameter)
  Excel format requires ImportExcel PowerShell module

"@
    exit 0
}

# Function to extract retirement data
function Get-RetirementData {
    Write-Host "Fetching latest model retirement data from Microsoft Azure AI docs..." -ForegroundColor Cyan
    
    # GitHub raw content URL - use raw.githubusercontent.com for actual markdown content
    $githubUrl = "https://raw.githubusercontent.com/MicrosoftDocs/azure-ai-docs/main/articles/foundry/openai/includes/retirement/models.md"
    
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
    
    # Split content into lines for processing - handle different line endings
    $lines = $content -split "`r?`n" | ForEach-Object { $_.Trim() }
    
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

# Generalized single-metric query function
# Based on the proven working pattern: az monitor metrics list --resource <id> --metric <single-metric> ...
function Get-SingleMetric {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceId,
        [Parameter(Mandatory)]
        [string]$MetricName,
        [Parameter(Mandatory)]
        [string]$StartTime,
        [Parameter(Mandatory)]
        [string]$EndTime,
        [string]$Interval = "PT1D",
        [string]$Aggregation = "Total",
        [string]$Dimension = "ModelDeploymentName"
    )

    # Print the full command for diagnostics (uncomment for debugging)
    # $cmd = "az monitor metrics list --resource `"$ResourceId`" --metric `"$MetricName`" --start-time `"$StartTime`" --end-time `"$EndTime`" --interval `"$Interval`" --aggregation `"$Aggregation`" --dimension `"$Dimension`" -o json"
    # Write-Host "      [CMD] $cmd" -ForegroundColor DarkGray

    $json = az monitor metrics list `
        --resource $ResourceId `
        --metric $MetricName `
        --start-time $StartTime `
        --end-time $EndTime `
        --interval $Interval `
        --aggregation $Aggregation `
        --dimension $Dimension `
        -o json 2>$null

    if (-not $json) { return @() }

    $parsed = ($json -join "") | ConvertFrom-Json
    $results = @()

    foreach ($metricValue in $parsed.value) {
        foreach ($ts in $metricValue.timeseries) {
            $deploymentName = ($ts.metadatavalues | Where-Object { $_.name.value -eq "modeldeploymentname" }).value
            if (-not $deploymentName) { continue }

            $total = ($ts.data | Where-Object { $null -ne $_.total } | Measure-Object -Property total -Sum).Sum
            if (-not $total) { $total = 0 }

            $results += [PSCustomObject]@{
                MetricName     = $metricValue.name.value
                DeploymentName = $deploymentName
                Total          = $total
            }
        }
    }

    return $results
}

# Function to collect Azure Monitor metrics for deployments
# Queries each metric individually for reliability (one az monitor metrics list call per metric)
function Get-DeploymentMetrics {
    param(
        [Parameter(Mandatory)]
        [hashtable]$ResourceIdMap,
        [int]$DaysBack = 7,
        [string]$Interval = "PT1D"
    )
    
    Write-Host "Collecting Azure Monitor metrics (last $DaysBack days, interval: $Interval)..." -ForegroundColor Cyan
    
    $startTime = (Get-Date).AddDays(-$DaysBack).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $endTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    
    # Result hashtable: "SubscriptionId|ResourceName|DeploymentName" -> metrics object
    $metricsLookup = @{}
    $resourceCount = 0
    $totalResourceCount = $ResourceIdMap.Count
    $metricsToQuery = @("AzureOpenAIRequests", "ProcessedPromptTokens", "GeneratedTokens")
    
    foreach ($key in $ResourceIdMap.Keys) {
        $resourceCount++
        $resourceId = $ResourceIdMap[$key]
        $parts = $key -split '\|'
        $subscriptionId = $parts[0]
        $resourceName = $parts[1]
        
        Write-Host "  [$resourceCount/$totalResourceCount] Querying metrics for: $resourceName" -ForegroundColor Yellow
        
        foreach ($metricName in $metricsToQuery) {
            try {
                # Write-Host "    Querying $metricName..." -ForegroundColor Gray
                $results = Get-SingleMetric `
                    -ResourceId $resourceId `
                    -MetricName $metricName `
                    -StartTime $startTime `
                    -EndTime $endTime `
                    -Interval $Interval

                foreach ($result in $results) {
                    $lookupKey = "$subscriptionId|$resourceName|$($result.DeploymentName)"

                    if (-not $metricsLookup.ContainsKey($lookupKey)) {
                        $metricsLookup[$lookupKey] = @{
                            TotalRequests   = 0
                            PromptTokens    = 0
                            GeneratedTokens = 0
                        }
                    }

                    switch ($result.MetricName) {
                        "AzureOpenAIRequests"    { $metricsLookup[$lookupKey].TotalRequests   += $result.Total }
                        "ProcessedPromptTokens"  { $metricsLookup[$lookupKey].PromptTokens    += $result.Total }
                        "GeneratedTokens"        { $metricsLookup[$lookupKey].GeneratedTokens += $result.Total }
                    }
                }

                # if ($results.Count -gt 0) {
                #     Write-Host "      ✓ $($results.Count) entries" -ForegroundColor Green
                # }
            } catch {
                Write-Host "      ✗ Error querying $metricName : $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    
    # Debug: show all keys in metricsLookup (uncomment for troubleshooting)
    # Write-Host "" -ForegroundColor Cyan
    # Write-Host "  [DEBUG] Metrics lookup keys ($($metricsLookup.Count) entries):" -ForegroundColor DarkGray
    # foreach ($lk in $metricsLookup.Keys) {
    #     $m = $metricsLookup[$lk]
    #     Write-Host "    $lk => Requests=$($m.TotalRequests), Prompt=$($m.PromptTokens), Generated=$($m.GeneratedTokens)" -ForegroundColor DarkGray
    # }
    
    Write-Host "✓ Metrics collected for $($metricsLookup.Count) deployment(s)" -ForegroundColor Green
    return $metricsLookup
}

# Function to join deployment data with metrics data
function Join-DeploymentWithMetrics {
    param(
        [Parameter(Mandatory)]
        $Deployments,
        [Parameter(Mandatory)]
        [hashtable]$MetricsData,
        [int]$DaysBack = 7
    )
    
    Write-Host "Joining deployment data with metrics information..." -ForegroundColor Cyan
    
    $joinedDeployments = @()
    $daysLabel = "${DaysBack}d"
    
    foreach ($deployment in $Deployments) {
        $lookupKey = "$($deployment.SubscriptionId)|$($deployment.Resource)|$($deployment.Deployment)"
        $metrics = $MetricsData[$lookupKey]
        
        # Debug: log unmatched keys (uncomment for troubleshooting)
        # if (-not $metrics) {
        #     Write-Host "    [DEBUG] No metrics match for key: $lookupKey" -ForegroundColor DarkGray
        # }
        
        # Build new object with all existing properties plus metrics
        $props = [ordered]@{}
        foreach ($prop in $deployment.PSObject.Properties) {
            $props[$prop.Name] = $prop.Value
        }
        
        # Add metrics columns with time period in column name
        $props["TotalRequests_$daysLabel"] = if ($metrics) { [math]::Round($metrics.TotalRequests) } else { "N/A" }
        $props["PromptTokens_$daysLabel"] = if ($metrics) { [math]::Round($metrics.PromptTokens) } else { "N/A" }
        $props["GeneratedTokens_$daysLabel"] = if ($metrics) { [math]::Round($metrics.GeneratedTokens) } else { "N/A" }
        
        $joinedDeployments += [PSCustomObject]$props
    }
    
    Write-Host "✓ Joined $($joinedDeployments.Count) deployment records with metrics data" -ForegroundColor Green
    return $joinedDeployments
}

# Start execution timer(minutes:seconds)
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Prerequisites check
Write-Host "Azure AI Deployments Scanner with Retirement Data v3.0" -ForegroundColor Green
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

# Show metrics configuration
if (-not $NoMetrics) {
    Write-Host "Metrics: enabled (last $DaysBack days)" -ForegroundColor Cyan
} else {
    Write-Host "Metrics: disabled via -NoMetrics parameter" -ForegroundColor Yellow
}
Write-Host ""

$allDeployments = @()
$resourceIdMap = @{}
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

# Show resource group filter
if ($ResourceGroupName -and $ResourceGroupName.Trim() -ne "") {
    Write-Host "Resource group filter: $ResourceGroupName" -ForegroundColor Cyan
}

Write-Host ""

# Scan each subscription
$subscriptionIndex = 0
foreach ($subscription in $subscriptions) {
    $subscriptionIndex++
    if ($subscriptions.Count -gt 1) {
        Write-Host "=== [$subscriptionIndex/$($subscriptions.Count)] SUBSCRIPTION: $($subscription.name) ($($subscription.id)) ===" -ForegroundColor Magenta
    }
    
    # Get all AI Services and OpenAI resources for this subscription
    $resources = az cognitiveservices account list --subscription $subscription.id --output json | ConvertFrom-Json | Where-Object { $_.kind -eq 'AIServices' -or $_.kind -eq 'OpenAI' } | Select-Object name, resourceGroup, id, @{Name='endpoint'; Expression={$_.properties.endpoint}}, @{Name='subscriptionId'; Expression={$subscription.id}}, @{Name='subscriptionName'; Expression={$subscription.name}}
    
    # Filter by resource group if specified
    if ($ResourceGroupName -and $ResourceGroupName.Trim() -ne "") {
        $resources = $resources | Where-Object { $_.resourceGroup -eq $ResourceGroupName }
    }
    
    if (-not $resources -or $resources.Count -eq 0) {
        $rgMsg = if ($ResourceGroupName -and $ResourceGroupName.Trim() -ne "") { " in resource group '$ResourceGroupName'" } else { "" }
        Write-Host "No AI Services resources found in this subscription$rgMsg." -ForegroundColor Yellow
        if ($subscriptions.Count -gt 1) {
            Write-Host ""
        }
        continue
    }
    
    $totalResources += $resources.Count
    $subscriptionResourceCount = $resources.Count
    $subscriptionProcessed = 0
    $rgMsg = if ($ResourceGroupName -and $ResourceGroupName.Trim() -ne "") { " in resource group '$ResourceGroupName'" } else { "" }
    Write-Host "Found $($resources.Count) AI resources in this subscription$rgMsg..." -ForegroundColor Green
    Write-Host ""
    
    foreach ($resource in $resources) {
        $subscriptionProcessed++
        Write-Host "[$subscriptionProcessed/$subscriptionResourceCount] Scanning: $($resource.name)" -ForegroundColor Yellow
        
        # Store resource ID for metrics lookup
        $resourceIdMap["$($resource.subscriptionId)|$($resource.name)"] = $resource.id
        
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

# Apply model filter early (before retirement join and metrics collection)
if (-not $All -and $ModelFilter -and $ModelFilter.Trim() -ne "") {
    $beforeCount = $allDeployments.Count
    $allDeployments = $allDeployments | Where-Object { $_.Model -like "*$ModelFilter*" }
    Write-Host ""
    Write-Host "Model filter '$ModelFilter': $beforeCount deployments -> $($allDeployments.Count) matching" -ForegroundColor Cyan

    # Also filter resourceIdMap to only query metrics for resources that have matching deployments
    $matchingResourceKeys = $allDeployments | ForEach-Object { "$($_.SubscriptionId)|$($_.Resource)" } | Select-Object -Unique
    $filteredResourceIdMap = @{}
    foreach ($key in $matchingResourceKeys) {
        if ($resourceIdMap.ContainsKey($key)) {
            $filteredResourceIdMap[$key] = $resourceIdMap[$key]
        }
    }
    $resourceIdMap = $filteredResourceIdMap
    Write-Host "Resources to query for metrics: $($resourceIdMap.Count)" -ForegroundColor Cyan
} elseif (-not $All -and (-not $ModelFilter -or $ModelFilter.Trim() -eq "")) {
    Write-Host ""
    Write-Host "Showing all deployments (use -ModelFilter to filter or -Help for options)" -ForegroundColor Cyan
}

# Join deployment data with retirement data if available and not disabled
If ($allDeployments.Count -gt 0 -and $hasRetirementData -and -not $NoRetirementData) {
    $allDeployments = Join-DeploymentWithRetirement -Deployments $allDeployments -RetirementData $retirementData
}

# Collect and join Azure Monitor metrics if not disabled
if (-not $NoMetrics -and $allDeployments.Count -gt 0) {
    Write-Host ""
    try {
        $metricsData = Get-DeploymentMetrics -ResourceIdMap $resourceIdMap -DaysBack $DaysBack -Interval "P1D"
    } catch {
        Write-Host "⚠ WARNING: Failed to collect metrics: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "⚠ WARNING: Continuing without metrics data. Metrics columns will show N/A." -ForegroundColor Yellow
        $metricsData = @{}
    }
    $allDeployments = Join-DeploymentWithMetrics -Deployments $allDeployments -MetricsData $metricsData -DaysBack $DaysBack
    Write-Host ""
} elseif ($NoMetrics) {
    Write-Host ""
    Write-Host "Metrics collection skipped (disabled via -NoMetrics)" -ForegroundColor Yellow
    Write-Host ""
}

# All filtering already applied — assign to output variable
$filteredDeployments = $allDeployments

Write-Host ""
# Write-Host "RESULTS:" -ForegroundColor Green
# Write-Host "========" -ForegroundColor Green

if ($filteredDeployments.Count -eq 0) {
    Write-Host "No deployments found." -ForegroundColor Red
} else {
    # Display results, uncomment for on-screen table output (not recommended for large datasets)
    # $filteredDeployments | Format-Table -AutoSize
    
    # Save results based on output format
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $fileSuffix = if ($NoMetrics) { "v3-nometrics" } else { "v3" }
    
    if ($OutputFormat -eq "Excel") {
        $timestampedFile = "deployments-results-$fileSuffix-$timestamp.xlsx"
        
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
        $timestampedFile = "deployments-results-$fileSuffix-$timestamp.csv"
        
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
    $stopwatch.Stop()
    $totalSeconds = [math]::Floor($stopwatch.Elapsed.TotalSeconds)
    $mins = [math]::Floor($totalSeconds / 60)
    $secs = $totalSeconds % 60
    $durationFormatted = "{0}m {1}s" -f $mins, $secs
    Write-Host ""
    Write-Host "SUMMARY:" -ForegroundColor Cyan
    Write-Host "Total deployments: $($filteredDeployments.Count)" -ForegroundColor White
    Write-Host "Total duration: $durationFormatted" -ForegroundColor White
    
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