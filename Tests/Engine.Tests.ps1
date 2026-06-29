BeforeAll {
    $script:EnginePath = Join-Path $PSScriptRoot '..' 'Invoke-LdoTerraform.ps1'
}

Describe 'Invoke-LdoTerraform.ps1' {

    It 'exists at the repository root' {
        Test-Path $EnginePath | Should -BeTrue
    }

    It 'parses without syntax errors' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path $EnginePath), [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    It 'declares the expected run-* parameters' -ForEach @(
        'RunTerraformInit', 'RunTerraformValidate', 'RunTerraformPlan',
        'RunTerraformPlanDestroy', 'RunTerraformApply', 'RunTerraformDestroy',
        'RunTfLint', 'RunTrivy'
    ) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path $EnginePath), [ref]$null, [ref]$null)
        $names = $ast.ParamBlock.Parameters.Name.VariablePath.UserPath
        $names | Should -Contain $_
    }
}
