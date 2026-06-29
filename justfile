# Libre DevOps terraform-azure action task runner. Run `just` to list recipes.
#
# Install just with either:
#   brew install just
#   uv tool add rust-just     # then call recipes as: uv run just <recipe>
#
# Recipes use PowerShell and the LibreDevOpsHelpers module, the same engine the action runs.

set shell := ["pwsh", "-NoProfile", "-Command"]

# List available recipes.
default:
    just --list

# Analyzer, format check, example validate, and the Pester tests.
validate:
    #!/usr/bin/env pwsh
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { Install-Module PSScriptAnalyzer -MinimumVersion 1.21.0 -Force -Scope CurrentUser }
    $results = Invoke-ScriptAnalyzer -Path ./Invoke-LdoTerraform.ps1 -Settings ./PSScriptAnalyzerSettings.psd1
    if (@($results | Where-Object { $_.Severity -eq 'Error' }).Count -gt 0) {
        $results | Format-Table -AutoSize | Out-String | Write-Host
        throw 'PSScriptAnalyzer found errors.'
    }
    Write-Host 'PSScriptAnalyzer: clean.'
    terraform fmt -check -recursive
    foreach ($d in @('examples/minimal', 'examples/complete')) {
        terraform -chdir=$d init -backend=false -input=false | Out-Null
        terraform -chdir=$d validate
    }

# Run the Pester tests.
test:
    #!/usr/bin/env pwsh
    if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge '5.5.0' })) { Install-Module Pester -MinimumVersion 5.5.0 -Force -Scope CurrentUser }
    Invoke-Pester -Path ./Tests -Output Detailed

# --- Release management -------------------------------------------------------------------
# Release flow for this action: bump and release a semver tag, then move the major alias, e.g.
#   just increment-release minor
#   just force-push-tag v1

# Create and push an annotated tag. Example: just tag v1.2.3
tag version:
    git tag -a '{{ version }}' -m 'Release {{ version }}'
    git push origin '{{ version }}'

# Bump the latest vX.Y.Z tag and push the new tag. level = patch (default), minor, or major.
increment-tag level="patch":
    #!/usr/bin/env pwsh
    $tags = @(git tag --list | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' })
    $cur = if ($tags.Count -eq 0) { [version]'0.0.0' } else { ($tags | ForEach-Object { [version]($_.Substring(1)) } | Sort-Object)[-1] }
    switch ('{{ level }}') {
        'major' { $next = "v$($cur.Major + 1).0.0" }
        'minor' { $next = "v$($cur.Major).$($cur.Minor + 1).0" }
        'patch' { $next = "v$($cur.Major).$($cur.Minor).$($cur.Build + 1)" }
        default { throw "level must be patch, minor, or major" }
    }
    git tag -a $next -m "Release $next"
    git push origin $next
    Write-Host "Tagged and pushed $next"

# Create a GitHub release from an existing tag, with auto-generated notes. Example: just release v1.2.3
release version:
    gh release create '{{ version }}' --title '{{ version }}' --generate-notes

# Tag a specific version and release it. Example: just tag-and-release v1.2.3
tag-and-release version:
    #!/usr/bin/env pwsh
    git tag -a '{{ version }}' -m 'Release {{ version }}'
    git push origin '{{ version }}'
    gh release create '{{ version }}' --title '{{ version }}' --generate-notes

# Bump the latest tag, push it, and create a release. level = patch (default), minor, or major.
increment-release level="patch":
    #!/usr/bin/env pwsh
    $tags = @(git tag --list | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' })
    $cur = if ($tags.Count -eq 0) { [version]'0.0.0' } else { ($tags | ForEach-Object { [version]($_.Substring(1)) } | Sort-Object)[-1] }
    switch ('{{ level }}') {
        'major' { $next = "v$($cur.Major + 1).0.0" }
        'minor' { $next = "v$($cur.Major).$($cur.Minor + 1).0" }
        'patch' { $next = "v$($cur.Major).$($cur.Minor).$($cur.Build + 1)" }
        default { throw "level must be patch, minor, or major" }
    }
    git tag -a $next -m "Release $next"
    git push origin $next
    gh release create $next --title $next --generate-notes
    Write-Host "Released $next"

# Bump, tag, and release in one step (same as increment-release). Example: just increment-tag-and-release minor
increment-tag-and-release level="patch":
    just increment-release {{ level }}

# Force-update a tag to a ref and push it, for example to move the v1 major alias. Example: just force-push-tag v1
force-push-tag tag ref="HEAD":
    git tag -f '{{ tag }}' '{{ ref }}'
    git push -f origin '{{ tag }}'
    @echo "Force-pushed {{ tag }} to {{ ref }}"
