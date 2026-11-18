param(
    [string]$InputPath = (Join-Path $PSScriptRoot '02_VAHAN_MASTER_CLEAN.csv'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '03_VAHAN_ANNUAL.csv')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([System.IO.Path]::GetFullPath($InputPath) -eq [System.IO.Path]::GetFullPath($OutputPath)) { throw 'Input and output paths must differ' }
$master = @(Import-Csv -LiteralPath $InputPath)
if ($master.Count -eq 0) { throw 'The clean master is empty' }
$requiredColumns = @('Year', 'Month', 'Maker_Clean', 'Vehicle Class', 'Registration Count / Value', 'Model_Clean', 'Vehicle_Category_Clean', 'Include_Main_Analysis', 'Complete_Year_Flag', 'E2W_Eligible', 'EV_Flag', 'Exclusion_Reason')
foreach ($column in $requiredColumns) {
    if ($column -notin $master[0].PSObject.Properties.Name) { throw "Missing input column: $column" }
}
$keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($row in $master) {
    if ($row.Year -notmatch '^\d{4}$' -or $row.Month -notmatch '^(?:[1-9]|1[0-2])$' -or $row.'Registration Count / Value' -notmatch '^\d+$' -or [string]::IsNullOrWhiteSpace($row.Maker_Clean)) { throw 'Invalid source period, maker or count' }
    if ($row.Include_Main_Analysis -notin @('Yes', 'No')) { throw 'Invalid analysis flag' }
    if (-not $keys.Add("$([int]$row.Year)`t$([int]$row.Month)`t$($row.Maker_Clean)`t$($row.'Vehicle Class')")) { throw 'Duplicate monthly source key' }
}
$selected = @($master | Where-Object {
    $_.Include_Main_Analysis -eq 'Yes' -or
    ($_.Complete_Year_Flag -eq 'No' -and $_.Exclusion_Reason -eq 'Incomplete calendar-year coverage')
})
if ($selected.Count -eq 0) { throw 'No eligible analysis rows' }
foreach ($row in $selected) {
    if ($row.Complete_Year_Flag -notin @('Yes', 'No') -or $row.E2W_Eligible -ne 'Yes' -or $row.EV_Flag -ne 'Electric') { throw 'Annual export requires eligible electric rows with valid coverage flags; review the master flags' }
}
$annual = @($selected | Group-Object -Property Year, Maker_Clean | ForEach-Object {
    $group = @($_.Group)
    $count = 0L
    foreach ($row in $group) { $count += [long]$row.'Registration Count / Value' }
    $models = @($group.Model_Clean | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne 'Unknown' } | Sort-Object -Unique)
    $categories = @($group.Vehicle_Category_Clean | Sort-Object -Unique)
    $category = 'Unknown'
    if (@($categories | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -eq 'Unknown' }).Count -eq 0) {
        $category = $categories -join '; '
    }
    [pscustomobject][ordered]@{
        Year = [int]$group[0].Year
        Maker = $group[0].Maker_Clean
        'Annual e-2W Registrations' = $count
        Models = $models -join '; '
        'Vehicle Category' = $category
        Annual_Registrations = $count
        'Market_Share_%' = ''
        Volume_Rank = 0
        Model_Count = $(if ($models.Count -gt 0) { $models.Count } else { '' })
        'YoY_Growth_%' = ''
        Complete_Year_Flag = $(if (@($group | Where-Object Complete_Year_Flag -ne 'Yes').Count -eq 0) { 'Yes' } else { 'No' })
    }
})
$lookup = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
foreach ($row in $annual) { $lookup.Add("$($row.Year)`t$($row.Maker)", $row) }
$culture = [System.Globalization.CultureInfo]::InvariantCulture
foreach ($yearGroup in $annual | Group-Object Year) {
    $yearRows = @($yearGroup.Group)
    $yearTotal = 0L
    foreach ($row in $yearRows) { $yearTotal += $row.Annual_Registrations }
    if ($yearTotal -le 0) { throw 'Annual share denominator must be positive' }
    foreach ($row in $yearRows) {
        $row.'Market_Share_%' = ([decimal]100 * $row.Annual_Registrations / $yearTotal).ToString('0.######', $culture)
        $row.Volume_Rank = 1 + @($yearRows | Where-Object { $_.Annual_Registrations -gt $row.Annual_Registrations }).Count
        $previousKey = "$($row.Year - 1)`t$($row.Maker)"
        if ($row.Complete_Year_Flag -eq 'Yes' -and $lookup.ContainsKey($previousKey) -and $lookup[$previousKey].Complete_Year_Flag -eq 'Yes' -and $lookup[$previousKey].Annual_Registrations -gt 0) {
            $previous = $lookup[$previousKey].Annual_Registrations
            $row.'YoY_Growth_%' = ([decimal]100 * ($row.Annual_Registrations - $previous) / $previous).ToString('0.######', $culture)
        }
    }
    $sourceTotal = 0L
    foreach ($row in $selected | Where-Object Year -eq $yearGroup.Name) { $sourceTotal += [long]$row.'Registration Count / Value' }
    if ($sourceTotal -ne $yearTotal) { throw "Annual count reconciliation failed: $($yearGroup.Name)" }
    $shareTotal = [decimal]0
    foreach ($row in $yearRows) { $shareTotal += [decimal]::Parse($row.'Market_Share_%', $culture) }
    if ([math]::Abs($shareTotal - 100) -gt [decimal]'0.0001') { throw 'Rounded annual shares do not sum to 100 percent' }
}
$annual = @($annual | Sort-Object Year, Volume_Rank, Maker)
$annual | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
$saved = @(Import-Csv -LiteralPath $OutputPath)
$columns = @($annual[0].PSObject.Properties.Name)
if ($saved.Count -ne $annual.Count -or ($saved[0].PSObject.Properties.Name -join '|') -cne ($columns -join '|')) { throw 'Annual CSV schema or row count mismatch' }
for ($index = 0; $index -lt $annual.Count; $index++) {
    foreach ($column in $columns) {
        if ([string]$saved[$index].$column -cne [string]$annual[$index].$column) { throw "Annual CSV round-trip mismatch: $index / $column" }
    }
}
Write-Output "Created $OutputPath with $($annual.Count) maker-year rows from $($selected.Count) eligible analysis rows."
Write-Output 'Shares and competition ranks are within each year of the selected Transport/for-hire analysis population, not the overall e-2W market.'
Write-Output 'Rows excluded solely for incomplete calendar-year coverage are included; other exclusions remain. Incomplete-year counts are observed period totals, not annualized estimates.'
Write-Output 'Both annual-registration columns contain the same measure. Models lists observed names; missing model evidence leaves Model_Count blank. Missing or zero prior-year counts, or incomplete coverage in either year, leave YoY growth blank.'
$annual | Group-Object Year | ForEach-Object {
    [pscustomobject]@{ Year = $_.Name; Makers = $_.Count; Registrations = ($_.Group | Measure-Object Annual_Registrations -Sum).Sum }
} | Format-Table -AutoSize