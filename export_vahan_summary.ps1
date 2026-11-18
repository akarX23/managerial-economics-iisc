param(
    [string]$InputPath = (Join-Path $PSScriptRoot '03_VAHAN_ANNUAL.csv'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '04_VAHAN_YEAR_SUMMARY.csv'),
    [string]$ThresholdOutputPath = (Join-Path $PSScriptRoot '05_VAHAN_REGISTRATION_THRESHOLDS.csv')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([System.IO.Path]::GetFullPath($InputPath) -eq [System.IO.Path]::GetFullPath($OutputPath)) { throw 'Input and output paths must differ' }
if ([System.IO.Path]::GetFullPath($ThresholdOutputPath) -in @([System.IO.Path]::GetFullPath($InputPath), [System.IO.Path]::GetFullPath($OutputPath))) { throw 'Threshold output must differ from the input and summary paths' }
$annual = @(Import-Csv -LiteralPath $InputPath)
if ($annual.Count -eq 0) { throw 'The annual dataset is empty' }
foreach ($column in @('Year', 'Maker', 'Annual_Registrations')) {
    if ($column -notin $annual[0].PSObject.Properties.Name) { throw "Missing column: $column" }
}
$keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($row in $annual) {
    if ($row.Year -notmatch '^\d{4}$' -or [string]::IsNullOrWhiteSpace($row.Maker) -or $row.Annual_Registrations -notmatch '^\d+$') { throw 'Invalid year, maker or registration count' }
    if (-not $keys.Add("$($row.Year)`t$($row.Maker)")) { throw 'Duplicate maker-year key' }
}

function Get-InclusivePercentile([decimal[]]$SortedValues, [decimal]$Probability) {
    if ($SortedValues.Count -eq 0 -or $Probability -lt 0 -or $Probability -gt 1) { throw 'Invalid percentile input' }
    $position = ($SortedValues.Count - 1) * $Probability
    $lower = [int][math]::Floor($position)
    $upper = [int][math]::Ceiling($position)
    return $SortedValues[$lower] + ($position - $lower) * ($SortedValues[$upper] - $SortedValues[$lower])
}

$metrics = @('Total e-2W registrations', 'Number of makers', 'Median registrations/maker', '25th percentile', '75th percentile', 'Largest maker volume')
$statistics = @{}
foreach ($year in 2024..2026) {
    $values = @($annual | Where-Object Year -eq ([string]$year) | ForEach-Object { [decimal]$_.Annual_Registrations } | Sort-Object)
    if ($values.Count -eq 0) { throw "No maker observations for $year; missing data must not become zero" }
    $total = [decimal]0
    foreach ($value in $values) { $total += $value }
    $statistics[$year] = @(
        $total
        $values.Count
        (Get-InclusivePercentile $values ([decimal]'0.5'))
        (Get-InclusivePercentile $values ([decimal]'0.25'))
        (Get-InclusivePercentile $values ([decimal]'0.75'))
        $values[-1]
    )
    if ($statistics[$year][3] -gt $statistics[$year][2] -or $statistics[$year][2] -gt $statistics[$year][4] -or $statistics[$year][4] -gt $values[-1]) { throw 'Inconsistent percentile ordering' }
}
$summary = @(for ($index = 0; $index -lt $metrics.Count; $index++) {
    $record = [ordered]@{ Metric = $metrics[$index] }
    foreach ($year in 2024..2026) {
        $record[[string]$year] = ([decimal]$statistics[$year][$index]).ToString('0.############################', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    [pscustomobject]$record
})
$summary | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
$saved = @(Import-Csv -LiteralPath $OutputPath)
$columns = @('Metric', '2024', '2025', '2026')
if ($saved.Count -ne 6 -or ($saved[0].PSObject.Properties.Name -join '|') -cne ($columns -join '|')) { throw 'Summary schema or row count mismatch' }
for ($index = 0; $index -lt $summary.Count; $index++) {
    foreach ($column in $columns) {
        if ($saved[$index].$column -cne $summary[$index].$column) { throw "Summary round-trip mismatch: $index / $column" }
    }
}
Write-Output "Created $OutputPath. Percentiles use inclusive linear interpolation (PERCENTILE.INC)."
Write-Output 'Statistics describe makers present in the filtered annual dataset, not the overall e-2W market. 2026 covers January-November and is not annualized.'
$summary | Format-Table -AutoSize

$pooledValues = @($annual | Where-Object { $_.Year -in @('2024', '2025', '2026') } | ForEach-Object { [decimal]$_.Annual_Registrations } | Sort-Object)
$thresholds = @(@(0) + @(foreach ($probability in @([decimal]'0.25', [decimal]'0.5', [decimal]'0.75')) {
    [long][math]::Floor((Get-InclusivePercentile $pooledValues $probability)) + 1
}) | Sort-Object -Unique)
$thresholdRows = @(foreach ($threshold in $thresholds) {
    $record = [ordered]@{ 'Annual registration threshold' = $threshold }
    foreach ($year in 2024..2026) {
        $record[[string]$year] = @($annual | Where-Object {
            $_.Year -eq [string]$year -and [decimal]$_.Annual_Registrations -ge $threshold
        }).Count
    }
    [pscustomobject]$record
})
foreach ($year in 2024..2026) {
    $previousCount = [int]$statistics[$year][1]
    foreach ($row in $thresholdRows) {
        $count = $row.([string]$year)
        if ($count -lt 0 -or $count -gt $previousCount) { throw "Invalid cumulative threshold count for $year" }
        $previousCount = $count
    }
}
$thresholdRows | Export-Csv -LiteralPath $ThresholdOutputPath -NoTypeInformation -Encoding UTF8
$savedThresholds = @(Import-Csv -LiteralPath $ThresholdOutputPath)
$thresholdColumns = @('Annual registration threshold', '2024', '2025', '2026')
if ($savedThresholds.Count -ne $thresholds.Count -or ($savedThresholds[0].PSObject.Properties.Name -join '|') -cne ($thresholdColumns -join '|')) { throw 'Threshold CSV schema or row count mismatch' }
for ($index = 0; $index -lt $thresholdRows.Count; $index++) {
    foreach ($column in $thresholdColumns) {
        if ([string]$savedThresholds[$index].$column -cne [string]$thresholdRows[$index].$column) { throw "Threshold round-trip mismatch: $index / $column" }
    }
}
Write-Output "Created $ThresholdOutputPath. Year columns count distinct makers with registrations greater than or equal to each threshold, independently within each year."
Write-Output 'Thresholds use pooled 2024-2026 maker-year quartiles: zero plus the smallest integer strictly above each quartile. Common cutoffs preserve cross-year comparability; ties remain together. Rebuilding with changed data recalculates the cutoffs.'
$thresholdRows | Format-Table -AutoSize
$bands = @(for ($index = 0; $index -lt $thresholds.Count; $index++) {
    $lower = $thresholds[$index]
    $upper = if ($index + 1 -lt $thresholds.Count) { $thresholds[$index + 1] } else { $null }
    $label = if ($null -eq $upper) { "$lower+" } else { "$lower-$($upper - 1)" }
    $band = [ordered]@{ 'Registration band' = $label }
    $pooledCount = 0
    foreach ($year in 2024..2026) {
        $count = $thresholdRows[$index].([string]$year)
        if ($null -ne $upper) { $count -= $thresholdRows[$index + 1].([string]$year) }
        if ($count -lt 0) { throw 'Negative band count' }
        $band[[string]$year] = $count
        $pooledCount += $count
    }
    $band['Pooled maker-years'] = $pooledCount
    [pscustomobject]$band
})
foreach ($year in 2024..2026) {
    if (($bands | Measure-Object -Property ([string]$year) -Sum).Sum -ne $statistics[$year][1]) { throw "Band coverage mismatch: $year" }
}
Write-Output 'Non-overlapping bands (pooled counts are maker-years, not distinct manufacturers across years):'
$bands | Format-Table -AutoSize