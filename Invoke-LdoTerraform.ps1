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

    # ---------- Conftest / OPA naming and policy checks (against the plan JSON) ----------
    [string]$RunConftest = "false",
    [string]$InstallConftest = "false",
    [string]$ConftestPoliciesPath = "",
    [string]$ConftestPoliciesRepo = "libre-devops/custom-policies",
    [string]$ConftestPoliciesRef = "main",
    [string]$ConftestFailOnWarn = "false",

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

    # ---------- Network Security Perimeter dance (open runner access, close after) ----------
    # When open-nsp-for-runner is true, an inbound access rule for the runner's current public IP is
    # added to the named perimeter profile before the run and always removed again in the finally
    # block, so a runner can reach a resource's data plane while it sits inside an Enforced Network
    # Security Perimeter. Off by default; opt in per run when a target is behind an enforced perimeter.
    [string]$OpenNspForRunner = "false",
    [string]$NspResourceGroup = "",
    [string]$NspName = "",
    [string]$NspProfileName = "",
    [string]$NspRuleName = "ldo-runner-allow",

    # ---------- Resource group management-lock dance (remove for the run, restore after) ----------
    # When true, after planning the engine finds the resource groups in the plan, captures and removes
    # any management lock on them so the apply/destroy is not blocked, and (on an apply only) restores
    # the captured locks in the finally block. The saved plan is applied without a refresh, so the
    # removed-then-restored lock never shows as drift. On a destroy the lock is removed and not put
    # back (the group is going away). This is the operational mirror of the firewall dance. Off by
    # default: opt in per run when you actually use resource group locks.
    [string]$RemoveResourceGroupLocksBeforeTfRun = "false",

    [string]$DeletePlanFiles = "true",
    [string]$EnablePrettyPrintOfFindings = "true",
    [string]$ExportGitContext = "true",
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

# Start with a clean findings store so the end-of-run summary reflects only this run.
Clear-LdoFinding

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
$addedNspIp = $false

# A shallow clone of the Conftest policies, if this run makes one; removed in the finally block.
$conftestTempClone = $null

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

    # A destroy run tears infrastructure down, so the lint/scan/policy gates are skipped: a
    # security finding on something being destroyed is not a reason to block the teardown.
    $isDestroyRun = $doPlanDestroy -or $doDestroy

    $createBackendKey = ConvertTo-LdoBoolean $TerraformInitCreateBackendStateFileName
    $backendKeyPrefix = ConvertTo-LdoNull $TerraformInitCreateBackendStateFilePrefix
    $backendKeySuffix = ConvertTo-LdoNull $TerraformInitCreateBackendStateFileSuffix

    $installTenv = ConvertTo-LdoBoolean $InstallTenvTerraform
    $createWorkspace = ConvertTo-LdoBoolean $CreateTerraformWorkspace

    $doTfLint = ConvertTo-LdoBoolean $RunTfLint
    $doInstallTfLint = ConvertTo-LdoBoolean $InstallTfLint
    $doTfLintSoftFail = ConvertTo-LdoBoolean $TfLintSoftFail

    $doTrivy = ConvertTo-LdoBoolean $RunTrivy
    $doInstallTrivy = ConvertTo-LdoBoolean $InstallTrivy
    $doTrivySoftFail = ConvertTo-LdoBoolean $TrivySoftFail

    $doConftest = ConvertTo-LdoBoolean $RunConftest
    $doInstallConftest = ConvertTo-LdoBoolean $InstallConftest
    $doConftestFailOnWarn = ConvertTo-LdoBoolean $ConftestFailOnWarn

    $doLockDance = ConvertTo-LdoBoolean $RemoveResourceGroupLocksBeforeTfRun

    $doInstallAzureCli = ConvertTo-LdoBoolean $InstallAzureCli
    $attemptLogin = ConvertTo-LdoBoolean $AttemptAzureLogin
    $useClientSecret = ConvertTo-LdoBoolean $UseAzureClientSecretLogin
    $useOidc = ConvertTo-LdoBoolean $UseAzureOidcLogin
    $useManagedIdentity = ConvertTo-LdoBoolean $UseAzureManagedIdentityLogin
    $useUserLogin = ConvertTo-LdoBoolean $UseAzureUserLogin

    $doDeletePlanFiles = ConvertTo-LdoBoolean $DeletePlanFiles
    $prettyPrintFindings = ConvertTo-LdoBoolean $EnablePrettyPrintOfFindings
    $doExportGitContext = ConvertTo-LdoBoolean $ExportGitContext

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

    # --- Export the git context as TF_VAR_* for the tags module --------------------------
    # Sets TF_VAR_deployed_branch / TF_VAR_deployed_repo from the checkout so a stack root variable
    # of the same name (forwarded into the tags module) produces DeployedBranch / DeployedRepo tags.
    if ($doExportGitContext) {
        try {
            Export-LdoGitContextToTfVar
        }
        catch {
            Write-LdoLog -Level WARN -Message "Could not export git context: $($_.Exception.Message)" -InvocationName $invocation
        }
    }

    # --- Tooling install ------------------------------------------------------------------
    if ($installTenv) {
        Install-LdoTenv
        Test-LdoTenv
        Invoke-LdoTenvTerraformInstall -TerraformVersion $TerraformVersion
    }
    Assert-LdoCommand -Name @('terraform')

    if ($doInstallTfLint -and $doTfLint) { Install-LdoTfLint }
    if ($doInstallTrivy -and $doTrivy) { Install-LdoTrivy }
    if ($doInstallConftest -and $doConftest) { Install-LdoConftest }
    if ($doInstallAzureCli -and $attemptLogin) { Install-LdoAzureCli }

    # --- Resolve the Conftest policy directory once (a local path, else a shallow clone) ------
    # The policies (libre-devops/custom-policies) are checked against the plan JSON after planning.
    # A caller-supplied path wins; otherwise the public policies repo is cloned at the given ref.
    $conftestPolicyDir = $null
    if ($doConftest) {
        if ($ConftestPoliciesPath -and (Test-Path $ConftestPoliciesPath)) {
            $conftestPolicyDir = (Resolve-Path $ConftestPoliciesPath).Path
            Write-LdoLog -Level INFO -Message "Using Conftest policies at $conftestPolicyDir" -InvocationName $invocation
        }
        elseif ($ConftestPoliciesRepo) {
            $conftestTempClone = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-conftest-policies-" + [guid]::NewGuid())
            $repoUrl = if ($ConftestPoliciesRepo -match '^https?://|\.git$') { $ConftestPoliciesRepo } else { "https://github.com/$ConftestPoliciesRepo.git" }
            Write-LdoLog -Level INFO -Message "Cloning Conftest policies $ConftestPoliciesRepo@$ConftestPoliciesRef" -InvocationName $invocation
            & git clone --depth 1 --branch $ConftestPoliciesRef $repoUrl $conftestTempClone
            Assert-LdoLastExitCode -Operation "clone conftest policies $ConftestPoliciesRepo@$ConftestPoliciesRef"
            $conftestPolicyDir = Join-Path $conftestTempClone 'policies'
        }

        if (-not ($conftestPolicyDir -and (Test-Path $conftestPolicyDir))) {
            Write-LdoLog -Level WARN -Message "run-conftest is true but no policy directory could be resolved; skipping Conftest." -InvocationName $invocation
            $doConftest = $false
        }
    }

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

    if (ConvertTo-LdoBoolean $OpenNspForRunner) {
        if ($NspResourceGroup -and $NspName -and $NspProfileName) {
            Add-LdoNspCurrentIpRule -ResourceGroup $NspResourceGroup -PerimeterName $NspName -ProfileName $NspProfileName -RuleName $NspRuleName
            $addedNspIp = $true
        }
        else {
            Write-LdoLog -Level WARN -Message "open-nsp-for-runner is true but the perimeter resource group, name, or profile name was not supplied; skipping the NSP step." -InvocationName $invocation
        }
    }

    # Azure firewall rule changes are not effective immediately. Wait for them to propagate before
    # Terraform touches the backend, or the first data-plane call fails with a 403.
    $propagationSeconds = [int]$FirewallPropagationSeconds
    if (($addedStorageIp -or $addedKvIp -or $addedNspIp) -and ($propagationSeconds -gt 0)) {
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

        # Lint and scan before planning, and fail closed unless soft-fail is set (skipped on a
        # destroy run). Switches and array arguments are only added to the splat when set: splatting
        # an empty array binds the parameter to $null, which then trips ".Count" under Set-StrictMode
        # inside the helper.
        if ($doTfLint -and -not $isDestroyRun) {
            $tfLintParams = @{ CodePath = $folder }
            if ($TfLintConfigFile) { $tfLintParams.ConfigFile = $TfLintConfigFile }
            if ($doTfLintSoftFail) { $tfLintParams.SoftFail = $true }
            if ($TfLintExtraArgs.Count -gt 0) { $tfLintParams.ExtraArgs = $TfLintExtraArgs }
            Invoke-LdoTfLint @tfLintParams
        }
        if ($doTrivy -and -not $isDestroyRun) {
            $trivySkip = if ([string]::IsNullOrWhiteSpace($TrivySkipChecks)) { @() } else { $TrivySkipChecks -split ',' | ForEach-Object { $_.Trim() } }
            $trivyParams = @{ CodePath = $folder }
            if ($doTrivySoftFail) { $trivyParams.SoftFail = $true }
            if ($trivySkip.Count -gt 0) { $trivyParams.TrivySkipChecks = $trivySkip }
            if ($TrivyExtraArgs.Count -gt 0) { $trivyParams.ExtraArgs = $TrivyExtraArgs }
            Invoke-LdoTrivy @trivyParams
        }

        if ($doPlan) {
            Invoke-LdoTerraformPlan -CodePath $folder -PlanFile $TerraformPlanFileName -PlanArgs $TerraformPlanExtraArgs
        }
        elseif ($doPlanDestroy) {
            Invoke-LdoTerraformPlanDestroy -CodePath $folder -PlanFile $TerraformDestroyPlanFileName -PlanArgs $TerraformPlanDestroyExtraArgs
        }

        # Policy-check the plan JSON with Conftest. Naming checks are informational (warn) and do
        # not fail the run unless conftest-fail-on-warn is set; deny rules always fail.
        if ($doPlan -and $doConftest) {
            $planJson = Convert-LdoTerraformPlanToJson -CodePath $folder -PlanFile $TerraformPlanFileName -PassThru
            $conftestParams = @{ PlanJsonPath = $planJson; PolicyPath = $conftestPolicyDir }
            if ($doConftestFailOnWarn) { $conftestParams.FailOnWarn = $true }
            Invoke-LdoConftest @conftestParams
        }

        # Re-show the lint/scan/policy findings now, after planning and before any apply, so they
        # are easy to read out of the verbose logs and reviewed before the change is made. Skipped
        # on a destroy run, where no gates ran (so there is nothing to summarise).
        if ($prettyPrintFindings) {
            Show-LdoFindingsSummary
        }

        if ($doApply) {
            # Lock-dance: take any management lock off the plan's resource groups so the apply is not
            # blocked, then restore exactly what was removed in the finally. The saved plan is applied
            # without a refresh, so the removed-then-restored lock is never seen as drift.
            $capturedLocks = @{ }
            if ($doLockDance) {
                $lockPlanJson = Convert-LdoTerraformPlanToJson -CodePath $folder -PlanFile $TerraformPlanFileName -PassThru
                foreach ($rg in Get-LdoResourceGroupNamesFromPlan -PlanJsonPath $lockPlanJson) {
                    $locks = @(Get-LdoResourceGroupLock -ResourceGroup $rg)
                    if ($locks.Count -gt 0) {
                        $capturedLocks[$rg] = $locks
                        foreach ($lock in $locks) { Remove-LdoResourceGroupLock -ResourceGroup $rg -LockName $lock.Name }
                    }
                }
            }
            try {
                Invoke-LdoTerraformApply -CodePath $folder -PlanFile $TerraformPlanFileName -SkipApprove -ApplyArgs $TerraformApplyExtraArgs
            }
            finally {
                foreach ($rg in $capturedLocks.Keys) {
                    foreach ($lock in $capturedLocks[$rg]) {
                        try {
                            Add-LdoResourceGroupLock -ResourceGroup $rg -LockName $lock.Name -LockLevel $lock.Level -Notes $lock.Notes
                        }
                        catch {
                            Write-LdoLog -Level WARN -Message "Failed to restore management lock '$($lock.Name)' on '$rg': $($_.Exception.Message)" -InvocationName $invocation
                        }
                    }
                }
            }
        }
        elseif ($doDestroy) {
            # Lock-dance: take locks off so Terraform can delete the (locked) groups. Nothing to
            # restore, the groups are being destroyed.
            if ($doLockDance) {
                $lockPlanJson = Convert-LdoTerraformPlanToJson -CodePath $folder -PlanFile $TerraformDestroyPlanFileName -PassThru
                foreach ($rg in Get-LdoResourceGroupNamesFromPlan -PlanJsonPath $lockPlanJson) {
                    Remove-LdoResourceGroupLock -ResourceGroup $rg
                }
            }
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
    if ($addedNspIp) {
        try {
            Remove-LdoNspRule -ResourceGroup $NspResourceGroup -PerimeterName $NspName -ProfileName $NspProfileName -RuleName $NspRuleName
        }
        catch {
            Write-LdoLog -Level WARN -Message "Failed to remove the NSP access rule: $($_.Exception.Message)" -InvocationName $invocation
        }
    }

    if ($doDeletePlanFiles) {
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

    # Remove the shallow policy clone if this run created one.
    if ($conftestTempClone -and (Test-Path $conftestTempClone)) {
        Remove-Item $conftestTempClone -Recurse -Force -ErrorAction SilentlyContinue
    }

    $env:TF_LOG = $null
    Set-Location $currentWorkingDirectory
}
