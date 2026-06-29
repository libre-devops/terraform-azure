<#
.SYNOPSIS
    Runs the Terraform lifecycle (init, validate, lint, scan, plan, apply, destroy) against
    Azure for one or more stacks, using the LibreDevOpsHelpers module.

.DESCRIPTION
    The engine behind the libre-devops/terraform-azure GitHub Action. String-typed boolean
    parameters are used so the composite action can pass them straight through. Boolean and
    JSON-array inputs are parsed once at the top, mutually exclusive combinations are rejected,
    and each stack is processed in turn (in reverse numeric order for destroys). Configuration is
    gated with tflint and trivy. All logging goes through Write-LdoLog on the OpenTelemetry
    format, with a trace started for the run and a fresh span per stack.
#>
param (
    [string]$TerraformCodeLocation = "examples",
    [string]$TerraformStackToRunJson = '["complete"]',

    [string]$RunTerraformInit = "true",
    [string]$RunTerraformValidate = "true",
    [string]$RunTerraformPlan = "true",
    [string]$RunTerraformPlanDestroy = "false",
    [string]$RunTerraformApply = "false",
    [string]$RunTerraformDestroy = "false",

    [string]$TerraformInitExtraArgsJson = '["-reconfigure", "-upgrade"]',
    [string]$TerraformInitCreateBackendStateFileName = "true",
    [string]$TerraformInitCreateBackendStateFilePrefix = "",
    [string]$TerraformInitCreateBackendStateFileSuffix = "",
    [string]$TerraformPlanExtraArgsJson = '[]',
    [string]$TerraformPlanDestroyExtraArgsJson = '[]',
    [string]$TerraformApplyExtraArgsJson = '[]',
    [string]$TerraformDestroyExtraArgsJson = '[]',

    [string]$TerraformPlanFileName = "tfplan.plan",
    [string]$TerraformDestroyPlanFileName = "tfplan-destroy.plan",

    [string]$InstallTenvTerraform = "true",
    [string]$TerraformVersion = "latest",

    [string]$CreateTerraformWorkspace = "true",
    [string]$TerraformWorkspace = "dev",

    [string]$RunTfLint = "true",
    [string]$InstallTfLint = "false",
    [string]$TfLintConfigFile = "",
    [string]$TfLintSoftFail = "false",
    [string]$TfLintExtraArgsJson = '[]',

    [string]$RunTrivy = "true",
    [string]$InstallTrivy = "false",
    [string]$TrivySkipChecks = "",
    [string]$TrivySoftFail = "false",
    [string]$TrivyExtraArgsJson = '[]',

    [string]$InstallAzureCli = "false",
    [string]$AttemptAzureLogin = "false",
    [string]$UseAzureClientSecretLogin = "false",
    [string]$UseAzureOidcLogin = "true",
    [string]$UseAzureManagedIdentityLogin = "false",
    [string]$UseAzureUserLogin = "false",

    # ---------- Firewall allow-listing (the storage and key vault "open then close") ----------
    # When true, the runner's current public IP is added to the named resource's firewall before
    # the Terraform run and always removed again in the finally block, so a firewalled remote
    # state account or key vault can be reached from an ephemeral runner without leaving the rule
    # behind.
    [string]$AddCurrentIpToStorageBeforeTfRun = "true",
    [string]$AddCurrentIpToKeyVaultBeforeTfRun = "false",
    [string]$FirewallStorageAccountName = "",
    [string]$FirewallStorageResourceGroup = "",
    [string]$FirewallKeyVaultName = "",
    [string]$FirewallKeyVaultResourceGroup = "",
    [string]$FirewallPropagationSeconds = "30",

    [string]$DeletePlanFiles = "true",
    [string]$DebugMode = "false",
    [string]$LogLevel = "INFO",
    [string]$LogFormat = "Json"
)

$ErrorActionPreference = 'Stop'
$currentWorkingDirectory = (Get-Location).Path
$fullTerraformCodePath = Join-Path -Path $currentWorkingDirectory -ChildPath $TerraformCodeLocation

# --- Load LibreDevOpsHelpers: PSGallery first, local file fallback ------------------------
# Primary path installs the published module from PSGallery. When that is not possible (for
# example an offline runner), fall back to importing a local copy pointed at by
# LDO_HELPERS_PATH, or a vendored copy beside this script.
try {
    Write-Host "Installing LibreDevOpsHelpers from PSGallery..."
    Install-Module LibreDevOpsHelpers -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    Import-Module LibreDevOpsHelpers -Force -ErrorAction Stop
}
catch {
    Write-Host "PSGallery install failed ($($_.Exception.Message)); trying a local copy..."
    $scriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
    $localCandidates = @(
        $env:LDO_HELPERS_PATH,
        (Join-Path $scriptDir 'LibreDevOpsHelpers/LibreDevOpsHelpers.psd1'),
        (Join-Path $scriptDir 'vendor/LibreDevOpsHelpers/LibreDevOpsHelpers.psd1')
    ) | Where-Object { $_ -and (Test-Path $_) }

    if (-not $localCandidates) {
        Write-Host "ERROR: could not install or locate LibreDevOpsHelpers."
        exit 1
    }
    Import-Module $localCandidates[0] -Force -ErrorAction Stop
}

# --- Logger configuration and a trace for the whole run -----------------------------------
if (-not $env:LDO_SERVICE_NAME) { $env:LDO_SERVICE_NAME = 'terraform-azure' }
Set-LdoLogLevel -Level ($LogLevel.ToUpperInvariant())
Set-LdoLogFormat -Format $LogFormat
Set-LdoTraceContext -Generate

$invocation = $MyInvocation.MyCommand.Name
Write-LdoLog -Level INFO -Message "LibreDevOpsHelpers loaded; starting terraform-azure run." -InvocationName $invocation

$convertedDebugMode = ConvertTo-LdoBoolean $DebugMode
if ($convertedDebugMode) {
    $Global:DebugPreference = 'Continue'
    $env:TF_LOG = 'DEBUG'
    Set-LdoLogLevel -Level 'DEBUG'
}
else {
    $Global:DebugPreference = 'SilentlyContinue'
}

$processedStacks = @()

# Track whether firewall rules were added so the finally block only removes what it added.
$addedStorageIp = $false
$addedKvIp = $false

try {
    # --- Parse JSON array inputs ----------------------------------------------------------
    $TerraformStackToRun = $TerraformStackToRunJson | ConvertFrom-Json
    if (-not ($TerraformStackToRun -is [System.Collections.IEnumerable])) {
        throw "TerraformStackToRunJson did not parse to an array."
    }
    $TerraformInitExtraArgs = @($TerraformInitExtraArgsJson | ConvertFrom-Json)
    $TerraformPlanExtraArgs = @($TerraformPlanExtraArgsJson | ConvertFrom-Json)
    $TerraformPlanDestroyExtraArgs = @($TerraformPlanDestroyExtraArgsJson | ConvertFrom-Json)
    $TerraformApplyExtraArgs = @($TerraformApplyExtraArgsJson | ConvertFrom-Json)
    $TerraformDestroyExtraArgs = @($TerraformDestroyExtraArgsJson | ConvertFrom-Json)
    $TfLintExtraArgs = @($TfLintExtraArgsJson | ConvertFrom-Json)
    $TrivyExtraArgs = @($TrivyExtraArgsJson | ConvertFrom-Json)

    # --- Convert string flags to booleans -------------------------------------------------
    $doInit = ConvertTo-LdoBoolean $RunTerraformInit
    $doValidate = ConvertTo-LdoBoolean $RunTerraformValidate
    $doPlan = ConvertTo-LdoBoolean $RunTerraformPlan
    $doPlanDestroy = ConvertTo-LdoBoolean $RunTerraformPlanDestroy
    $doApply = ConvertTo-LdoBoolean $RunTerraformApply
    $doDestroy = ConvertTo-LdoBoolean $RunTerraformDestroy

    $createBackendKey = ConvertTo-LdoBoolean $TerraformInitCreateBackendStateFileName
    $backendKeyPrefix = ConvertTo-LdoNull $TerraformInitCreateBackendStateFilePrefix
    $backendKeySuffix = ConvertTo-LdoNull $TerraformInitCreateBackendStateFileSuffix

    $installTenv = ConvertTo-LdoBoolean $InstallTenvTerraform
    $createWorkspace = ConvertTo-LdoBoolean $CreateTerraformWorkspace

    $doTfLint = ConvertTo-LdoBoolean $RunTfLint
    $installTfLint = ConvertTo-LdoBoolean $InstallTfLint
    $tfLintSoftFail = ConvertTo-LdoBoolean $TfLintSoftFail

    $doTrivy = ConvertTo-LdoBoolean $RunTrivy
    $installTrivy = ConvertTo-LdoBoolean $InstallTrivy
    $trivySoftFail = ConvertTo-LdoBoolean $TrivySoftFail

    $installAzureCli = ConvertTo-LdoBoolean $InstallAzureCli
    $attemptLogin = ConvertTo-LdoBoolean $AttemptAzureLogin
    $useClientSecret = ConvertTo-LdoBoolean $UseAzureClientSecretLogin
    $useOidc = ConvertTo-LdoBoolean $UseAzureOidcLogin
    $useManagedIdentity = ConvertTo-LdoBoolean $UseAzureManagedIdentityLogin
    $useUserLogin = ConvertTo-LdoBoolean $UseAzureUserLogin

    $deletePlanFiles = ConvertTo-LdoBoolean $DeletePlanFiles

    # --- Mutual exclusivity and ordering guards -------------------------------------------
    if (-not $doInit -and ($doPlan -or $doPlanDestroy -or $doApply -or $doDestroy)) {
        throw "Terraform init must run before plan, apply, or destroy operations."
    }
    if ($doPlan -and $doPlanDestroy) {
        throw "run-terraform-plan and run-terraform-plan-destroy cannot both be true."
    }
    if ($doApply -and $doDestroy) {
        throw "run-terraform-apply and run-terraform-destroy cannot both be true."
    }
    if ($doApply -and -not $doPlan) {
        throw "run-terraform-apply requires run-terraform-plan to be true."
    }
    if ($doDestroy -and -not $doPlanDestroy) {
        throw "run-terraform-destroy requires run-terraform-plan-destroy to be true."
    }

    # --- Tooling install ------------------------------------------------------------------
    if ($installTenv) {
        Install-LdoTenv
        Test-LdoTenv
        Invoke-LdoTenvTerraformInstall -TerraformVersion $TerraformVersion
    }
    Assert-LdoCommand -Name @('terraform')

    if ($installTfLint -and $doTfLint) { Install-LdoTfLint }
    if ($installTrivy -and $doTrivy) { Install-LdoTrivy }
    if ($installAzureCli -and $attemptLogin) { Install-LdoAzureCli }

    # --- Optional Azure CLI login (the composite action normally handles OIDC login) ------
    if ($attemptLogin) {
        Assert-LdoCommand -Name @('az')
        if ($useOidc) {
            Connect-LdoAzureCliOidc -ClientId $env:ARM_CLIENT_ID -OidcToken $env:ARM_OIDC_TOKEN -TenantId $env:ARM_TENANT_ID -SubscriptionId $env:ARM_SUBSCRIPTION_ID
        }
        elseif ($useClientSecret) {
            Connect-LdoAzureCliClientSecret -ClientId $env:ARM_CLIENT_ID -ClientSecret $env:ARM_CLIENT_SECRET -TenantId $env:ARM_TENANT_ID -SubscriptionId $env:ARM_SUBSCRIPTION_ID
        }
        elseif ($useManagedIdentity) {
            Connect-LdoAzureCliManagedIdentity -SubscriptionId $env:ARM_SUBSCRIPTION_ID
        }
        elseif ($useUserLogin) {
            Connect-LdoAzureCliDeviceCode -TenantId $env:ARM_TENANT_ID -SubscriptionId $env:ARM_SUBSCRIPTION_ID
        }
        else {
            Write-LdoLog -Level WARN -Message "attempt-azure-login is true but no login method is selected; skipping login." -InvocationName $invocation
        }
    }

    # --- Firewall allow-listing: open the current runner IP before the run ----------------
    # The matching removal is in the finally block, so the rule is always taken away again.
    if (ConvertTo-LdoBoolean $AddCurrentIpToStorageBeforeTfRun) {
        if ($FirewallStorageAccountName -and $FirewallStorageResourceGroup) {
            Add-LdoStorageCurrentIpRule -ResourceGroup $FirewallStorageResourceGroup -StorageAccountName $FirewallStorageAccountName
            $addedStorageIp = $true
        }
        else {
            Write-LdoLog -Level WARN -Message "add-current-ip-to-storage-before-tf-run is true but the storage account name or resource group was not supplied; skipping the storage firewall step." -InvocationName $invocation
        }
    }
    if (ConvertTo-LdoBoolean $AddCurrentIpToKeyVaultBeforeTfRun) {
        if ($FirewallKeyVaultName -and $FirewallKeyVaultResourceGroup) {
            Add-LdoKeyVaultCurrentIpRule -ResourceGroup $FirewallKeyVaultResourceGroup -KeyVaultName $FirewallKeyVaultName
            $addedKvIp = $true
        }
        else {
            Write-LdoLog -Level WARN -Message "add-current-ip-to-key-vault-before-tf-run is true but the key vault name or resource group was not supplied; skipping the key vault firewall step." -InvocationName $invocation
        }
    }

    # Azure firewall rule changes are not effective immediately. Wait for them to propagate before
    # Terraform touches the backend, or the first data-plane call fails with a 403.
    $propagationSeconds = [int]$FirewallPropagationSeconds
    if (($addedStorageIp -or $addedKvIp) -and ($propagationSeconds -gt 0)) {
        Write-LdoLog -Level INFO -Message "Waiting ${propagationSeconds}s for firewall rules to propagate." -InvocationName $invocation
        Start-Sleep -Seconds $propagationSeconds
    }

    # --- Resolve stacks, reversing order for destroys -------------------------------------
    $stackFolders = Get-LdoTerraformStackFolders -CodeRoot $fullTerraformCodePath -StacksToRun $TerraformStackToRun

    if ($doPlanDestroy -or $doDestroy) {
        $numericFolders = $stackFolders |
            Where-Object { ($_ -split '[\\/]+')[-1] -match '^\d+_' } |
            Sort-Object { [int](($_ -split '[\\/]+')[-1] -replace '^(\d+)_.*', '$1') } -Descending
        $otherFolders = $stackFolders | Where-Object { $_ -notin $numericFolders }
        $stackFolders = @($numericFolders) + @($otherFolders)
        Write-LdoLog -Level INFO -Message "Destroy run: processing stacks in reverse order: $($stackFolders -join ', ')" -InvocationName $invocation
    }

    foreach ($folder in $stackFolders) {
        # A fresh span per stack keeps the run as one trace with a span per unit of work.
        Set-LdoTraceContext -SpanId (New-LdoSpanId)
        $processedStacks += $folder
        Write-LdoLog -Level INFO -Message "Processing stack: $folder" -InvocationName $invocation -Data @{ stack = $folder }

        Invoke-LdoTerraformFmtCheck -CodePath $folder

        if ($doInit) {
            if ($createBackendKey) {
                Invoke-LdoTerraformInit -CodePath $folder -InitArgs $TerraformInitExtraArgs -CreateBackendKey -StackFolderName $folder -BackendKeyPrefix $backendKeyPrefix -BackendKeySuffix $backendKeySuffix
            }
            else {
                Invoke-LdoTerraformInit -CodePath $folder -InitArgs $TerraformInitExtraArgs
            }
        }

        if ($doInit -and $createWorkspace -and -not [string]::IsNullOrWhiteSpace($TerraformWorkspace)) {
            Invoke-LdoTerraformWorkspaceSelect -CodePath $folder -WorkspaceName $TerraformWorkspace
        }

        if ($doInit -and $doValidate) {
            Invoke-LdoTerraformValidate -CodePath $folder
        }

        # Lint and scan before planning, and fail closed unless soft-fail is set. The -SoftFail
        # switch is added via splatting only when true, which avoids the fragile -SoftFail:$bool
        # binding form.
        if ($doTfLint) {
            $tfLintParams = @{ CodePath = $folder; ExtraArgs = $TfLintExtraArgs }
            if ($TfLintConfigFile) { $tfLintParams.ConfigFile = $TfLintConfigFile }
            if ($tfLintSoftFail) { $tfLintParams.SoftFail = $true }
            Invoke-LdoTfLint @tfLintParams
        }
        if ($doTrivy) {
            $trivySkip = if ([string]::IsNullOrWhiteSpace($TrivySkipChecks)) { @() } else { $TrivySkipChecks -split ',' | ForEach-Object { $_.Trim() } }
            $trivyParams = @{ CodePath = $folder; TrivySkipChecks = $trivySkip; ExtraArgs = $TrivyExtraArgs }
            if ($trivySoftFail) { $trivyParams.SoftFail = $true }
            Invoke-LdoTrivy @trivyParams
        }

        if ($doPlan) {
            Invoke-LdoTerraformPlan -CodePath $folder -PlanFile $TerraformPlanFileName -PlanArgs $TerraformPlanExtraArgs
        }
        elseif ($doPlanDestroy) {
            Invoke-LdoTerraformPlanDestroy -CodePath $folder -PlanFile $TerraformDestroyPlanFileName -PlanArgs $TerraformPlanDestroyExtraArgs
        }

        if ($doApply) {
            Invoke-LdoTerraformApply -CodePath $folder -PlanFile $TerraformPlanFileName -SkipApprove -ApplyArgs $TerraformApplyExtraArgs
        }
        elseif ($doDestroy) {
            Invoke-LdoTerraformDestroy -CodePath $folder -PlanFile $TerraformDestroyPlanFileName -SkipApprove -DestroyArgs $TerraformDestroyExtraArgs
        }

        Write-LdoLog -Level SUCCESS -Message "Stack completed: $folder" -InvocationName $invocation -Data @{ stack = $folder }
    }

    Write-LdoLog -Level SUCCESS -Message "terraform-azure run completed for $($processedStacks.Count) stack(s)." -InvocationName $invocation
}
catch {
    Write-LdoLog -Level ERROR -Message "Run failed: $($_.Exception.Message)" -InvocationName $invocation
    exit 1
}
finally {
    # Always remove any firewall rule this run added, even on failure, so nothing is left open.
    if ($addedStorageIp) {
        try {
            Remove-LdoStorageCurrentIpRule -ResourceGroup $FirewallStorageResourceGroup -StorageAccountName $FirewallStorageAccountName
        }
        catch {
            Write-LdoLog -Level WARN -Message "Failed to remove the storage firewall rule: $($_.Exception.Message)" -InvocationName $invocation
        }
    }
    if ($addedKvIp) {
        try {
            Remove-LdoKeyVaultCurrentIpRule -ResourceGroup $FirewallKeyVaultResourceGroup -KeyVaultName $FirewallKeyVaultName
        }
        catch {
            Write-LdoLog -Level WARN -Message "Failed to remove the key vault firewall rule: $($_.Exception.Message)" -InvocationName $invocation
        }
    }

    if ($deletePlanFiles) {
        $patterns = @($TerraformPlanFileName, "$TerraformPlanFileName.json", $TerraformDestroyPlanFileName, "$TerraformDestroyPlanFileName.json")
        foreach ($folder in $processedStacks) {
            foreach ($pattern in $patterns) {
                $file = Join-Path $folder $pattern
                if (Test-Path $file) {
                    Remove-Item $file -Force -ErrorAction SilentlyContinue
                    Write-LdoLog -Level DEBUG -Message "Deleted plan file: $file" -InvocationName $invocation
                }
            }
        }
    }

    if ($attemptLogin -and $useUserLogin) {
        Disconnect-LdoAzureCli
    }

    $env:TF_LOG = $null
    Set-Location $currentWorkingDirectory
}
