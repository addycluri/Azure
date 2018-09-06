
# Walk through the specified folders and import the cmdlet modules.
$modulePathsToInclude = (
    "$PSScriptRoot\Main\*.ps1"
)

$modulePathsToInclude | Resolve-Path | ForEach-Object { . $_.ProviderPath }
