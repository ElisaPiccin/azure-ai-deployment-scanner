# Troubleshooting Guide

This guide provides solutions to common issues when running the Azure AI Deployments Scanner.

## Azure Cloud Shell Issues

### "Script not found" or permission denied
```powershell
# Ensure you're in the correct directory
ls

# Make script executable (if needed)
chmod +x Get-AzureAIDeployments.ps1

# Run with explicit path
./Get-AzureAIDeployments.ps1
```

### ImportExcel module issues in Cloud Shell
The script automatically installs the ImportExcel module if needed. If issues occur:
```powershell
# Fallback to CSV format
./Get-AzureAIDeployments.ps1 -OutputFormat CSV
```

## Local Execution Issues

### "Azure CLI not found"
```powershell
# Install Azure CLI
winget install Microsoft.AzureCLI
# Or download from: https://aka.ms/installazurecliwindows
```

### "Command 'cognitiveservices' not found"
This usually means your Azure CLI is outdated:

```powershell
# Update Azure CLI to latest version
az upgrade

# Verify cognitive services commands are available
az cognitiveservices --help
```

### "Not logged in to Azure"
```powershell
az login
```

### JSON Deserialization Errors
If you encounter JSON parsing errors, try these solutions:

```powershell
# Check Azure CLI version (needs 2.37.0+ for cognitive services)
az --version

# Update Azure CLI if needed
az upgrade

# For PowerShell 5.1 users experiencing JSON issues:
# Consider upgrading to PowerShell 7
winget install Microsoft.PowerShell

# Test the cognitive services command manually:
az cognitiveservices account list --output json

# If command not found, update Azure CLI:
az upgrade
```

**Common causes**:
- **Old Azure CLI version**: Update to latest version
- **PowerShell 5.1 JSON limitations**: Upgrade to PowerShell 7
- **Empty or malformed JSON responses**: Check your permissions and resource access

### Script Fails or Returns Incomplete Data
If the script runs but produces errors or incomplete results:

```powershell
# Check PowerShell version (7+ recommended)
$PSVersionTable.PSVersion

# Update Azure CLI to latest version
az upgrade

# Verify cognitive services commands are working
az cognitiveservices --help
az cognitiveservices account list --output json
```

**Common causes**:
- **Outdated Azure CLI**: Update with `az upgrade`
- **PowerShell version**: Use PowerShell 7+ for better reliability
- **Network timeouts**: CLI updates can resolve API communication issues

### "No AI Services resources found"
- Check you're in the correct subscription: `az account show`
- Switch subscriptions: `az account set --subscription "subscription-name"`
- Verify you have permissions to list Cognitive Services resources

### Get Your Subscription ID
```powershell
# Show current subscription
az account show --query id --output tsv

# List all subscriptions
az account list --query "[].{name:name, id:id, isDefault:isDefault}" --output table
```