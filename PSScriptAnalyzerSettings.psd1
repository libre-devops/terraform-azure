@{
    # PSAvoidUsingWriteHost: the helper bootstrap intentionally uses Write-Host before the
    #   LibreDevOpsHelpers logger is available.
    # PSUseShouldProcessForStateChangingFunctions: the engine is a thin orchestration script
    #   around external CLIs where ShouldProcess adds noise without value.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseShouldProcessForStateChangingFunctions'
    )

    Rules = @{
        PSUseConsistentIndentation = @{
            Enable          = $true
            Kind            = 'space'
            IndentationSize = 4
        }
        PSUseConsistentWhitespace = @{
            Enable = $true
        }
        PSPlaceOpenBrace = @{
            Enable     = $true
            OnSameLine = $true
        }
        PSPlaceCloseBrace = @{
            Enable = $true
        }
    }
}
