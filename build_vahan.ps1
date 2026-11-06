param(
    [string]$DataDirectory = (Join-Path $PSScriptRoot 'source_data'),
    [string]$OutputDirectory = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-VahanTable([string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path).Replace('\n\n', "`n`n")
    $header = [regex]::Match($text, '(?m)^(?:"Maker"|Month),')
    if (-not $header.Success) { throw "Missing CSV header: $Path" }
    $parsed = @($text.Substring($header.Index) | ConvertFrom-Csv)
    if ($parsed.Count -eq 0) { throw "Empty table: $Path" }
    $columns = @($parsed[0].PSObject.Properties.Name)
    $keyColumn = $columns[0]
    $totalColumns = @($columns | Where-Object { $_ -match '^Total(?: Consolidated)?$' })
    if ($totalColumns.Count -ne 1) { throw "Missing or ambiguous total: $Path" }
    $totalColumn = $totalColumns[0]
    $dimensions = @($columns | Where-Object { $_ -ne $keyColumn -and $_ -ne $totalColumn })
    $records = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    $footers = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $parsed) {
        foreach ($column in $columns | Where-Object { $_ -ne $keyColumn }) {
            if ($record.$column -notmatch '^\d+$') { throw "Invalid count: $Path / $($record.$keyColumn) / $column" }
            $record.$column = [long]$record.$column
        }
        if ($dimensions.Count -gt 0) {
            $sum = 0L
            foreach ($column in $dimensions) { $sum += $record.$column }
            if ($sum -ne $record.$totalColumn) { throw "Row total mismatch: $Path / $($record.$keyColumn)" }
        }
        $key = [string]$record.$keyColumn
        if ($key -match '^(?:Grand )?Total$') {
            $footers.Add($record)
        } else {
            if ([string]::IsNullOrWhiteSpace($key) -or $records.ContainsKey($key)) { throw "Empty or duplicate key: $Path / $key" }
            $records.Add($key, $record)
        }
    }
    foreach ($footer in $footers) {
        foreach ($column in $columns | Where-Object { $_ -ne $keyColumn }) {
            $sum = 0L
            foreach ($record in $records.Values) { $sum += $record.$column }
            if ($sum -ne $footer.$column) { throw "Footer total mismatch: $Path / $column" }
        }
    }
    $description = ($text -split '\r?\n', 2)[0].Trim('"')
    $scope = [regex]::Match($description, ' Data for (.+) \((\d{4}(?:-\d{4})?)\)$')
    $classFilter = [regex]::Match($description, ', Class \((.*?)\), EV Type \(')
    $filterEnd = $description.IndexOf(' Wise ')
    if (-not $scope.Success -or -not $classFilter.Success -or $filterEnd -lt 0) { throw "Unrecognized export metadata: $Path" }
    [pscustomobject]@{
        File = [System.IO.Path]::GetFileName($Path)
        KeyColumn = $keyColumn
        TotalColumn = $totalColumn
        Dimensions = $dimensions
        Records = $records
        ClassFilter = $classFilter.Groups[1].Value
        Filters = $description.Substring(0, $filterEnd)
        Geography = $scope.Groups[1].Value
        Period = $scope.Groups[2].Value
    }
}

function Add-Count($Counter, [string]$Key, [long]$Value) {
    if (-not $Counter.ContainsKey($Key)) { $Counter.Add($Key, 0L) }
    $Counter[$Key] += $Value
}

function Assert-Count($Counter, [string]$Key, [long]$Expected, [string]$Context) {
    $actual = 0L
    if ($Counter.ContainsKey($Key)) { $actual = $Counter[$Key] }
    if ($actual -ne $Expected) { throw "Count mismatch ($Context): $Key; expected $Expected, found $actual" }
}

function Get-Attribute([int]$Year, [string]$Maker, [string]$MonthKey, [string]$Family, [string]$MonthlyFile = '') {
    $annualTable = $tables["maker_${Family}_${Year}_all_records.csv"]
    $annualRecord = $annualTable.Records[$Maker]
    $candidates = @($annualTable.Dimensions | Where-Object { $annualRecord.$_ -gt 0 })
    if ($MonthlyFile -ne '') {
        $monthlyTable = $tables[$MonthlyFile]
        $monthlyRecord = $monthlyTable.Records[$MonthKey]
        $monthlyCandidates = @($monthlyTable.Dimensions | Where-Object { $monthlyRecord.$_ -gt 0 })
        $candidates = @($candidates | Where-Object { $monthlyCandidates -ccontains $_ })
    }
    if ($candidates.Count -eq 0) { throw "Conflicting attribute evidence: $Year / $Maker / $MonthKey / $Family" }
    if ($candidates.Count -eq 1) { return $candidates[0] }
    return ''
}

$tables = @{}
foreach ($file in (Get-ChildItem -LiteralPath $DataDirectory -Filter '*.csv' -File | Where-Object { $_.Name -like 'maker_*.csv' -or $_.Name -like 'month-wise*.csv' })) {
    $tables[$file.Name] = Read-VahanTable $file.FullName
}
$monthlyFamilies = @{
    vehicleClass = 'month-wise-vehicle-class.csv'
    vehicleFuel = 'month-wise-fuel.csv'
    vehicleCategoryDescription = 'month-wise-vehicle-category.csv'
    vehicleOwnerType = 'month-wise-owner-type.csv'
    vehicleType = 'month-wise-vehicle-type.csv'
}
foreach ($table in $tables.Values) {
    if ($table.File -match '^maker_(.+)_(202[456])_all_records\.csv$') {
        $family = $Matches[1]
        $year = [int]$Matches[2]
        $baseline = $tables["maker_monthWise_${year}_all_records.csv"]
        if ($table.Period -ne [string]$year -or $table.Filters -cne $baseline.Filters -or $table.Geography -cne $baseline.Geography) { throw "Inconsistent original export scope: $($table.File)" }
        if ($table.Records.Count -ne $baseline.Records.Count) { throw "Maker coverage mismatch: $($table.File)" }
        foreach ($maker in $table.Records.Keys) {
            if (-not $baseline.Records.ContainsKey($maker) -or $table.Records[$maker].Total -ne $baseline.Records[$maker].Total) { throw "Maker total mismatch: $($table.File) / $maker" }
        }
        if ($monthlyFamilies.ContainsKey($family)) {
            $monthlyTable = $tables[$monthlyFamilies[$family]]
            $monthlyRecords = @($monthlyTable.Records.Values | Where-Object { $_.Month.StartsWith([string]$year) })
            foreach ($dimension in @($table.Dimensions + $monthlyTable.Dimensions | Sort-Object -Unique)) {
                $annualCount = 0L
                $monthlyCount = 0L
                if ($table.Dimensions -ccontains $dimension) {
                    foreach ($record in $table.Records.Values) { $annualCount += $record.$dimension }
                }
                if ($monthlyTable.Dimensions -ccontains $dimension) {
                    foreach ($record in $monthlyRecords) { $monthlyCount += $record.$dimension }
                }
                if ($annualCount -ne $monthlyCount) { throw "Annual/monthly dimension mismatch: $year / $family / $dimension" }
            }
        }
    }
}
$suffixes = @{
    for_hire = 'Motor Cycle/Scooter-Used For Hire'
    sidecar = 'Motor Cycle/Scooter-SideCar(T)'
    with_trailer = 'Motor Cycle/Scooter-With Trailer'
}
$records = [System.Collections.Generic.List[object]]::new()
$makerMonths = [System.Collections.Generic.Dictionary[string,long]]::new([System.StringComparer]::Ordinal)
$makerClasses = [System.Collections.Generic.Dictionary[string,long]]::new([System.StringComparer]::Ordinal)
$monthClasses = [System.Collections.Generic.Dictionary[string,long]]::new([System.StringComparer]::Ordinal)
$monthTotals = [System.Collections.Generic.Dictionary[string,long]]::new([System.StringComparer]::Ordinal)
$coveredMonths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$recordKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$sourceCount = 0
foreach ($year in 2024..2026) {
    $baseline = $tables["maker_monthWise_${year}_all_records.csv"]
    $classTotals = $tables["maker_vehicleClass_${year}_all_records.csv"]
    foreach ($suffix in $suffixes.Keys | Sort-Object) {
        $class = $suffixes[$suffix]
        $filename = "maker_monthWise_${year}_${suffix}.csv"
        if (-not $tables.ContainsKey($filename)) {
            if ($classTotals.Dimensions -contains $class) {
                foreach ($record in $classTotals.Records.Values) {
                    if ($record.$class -gt 0) { throw "Missing class-specific export: $filename" }
                }
            }
            continue
        }
        $source = $tables[$filename]
        $sourceCount++
        $normalizedFilters = $source.Filters -replace ', Class \(.*?\), EV Type \(', ', Class (*), EV Type ('
        $baselineFilters = $baseline.Filters -replace ', Class \(.*?\), EV Type \(', ', Class (*), EV Type ('
        if ($source.ClassFilter -cne $class -or $source.Period -ne [string]$year -or $source.Geography -cne $baseline.Geography -or $normalizedFilters -cne $baselineFilters) {
            throw "Class, year, geography or filter mismatch: $filename"
        }
        if (($source.Dimensions -join '|') -cne ($baseline.Dimensions -join '|')) { throw "Month coverage mismatch: $filename" }
        foreach ($record in $source.Records.Values) {
            $maker = $record.Maker
            if (-not $baseline.Records.ContainsKey($maker)) { throw "Unexpected maker: $filename / $maker" }
            foreach ($column in $source.Dimensions) {
                $date = [datetime]::ParseExact($column, 'yyyy-MMM', [System.Globalization.CultureInfo]::InvariantCulture)
                if ($date.Year -ne $year) { throw "Unexpected month: $filename / $column" }
                $count = [long]$record.$column
                if ($count -eq 0) { continue }
                $month = $date.Month
                $monthKey = $date.ToString('yyyy-MM')
                if (-not $recordKeys.Add("$year`t$month`t$maker`t$class")) { throw "Duplicate output grain: $filename / $maker / $column" }
                $records.Add([pscustomobject][ordered]@{
                    Year = $year
                    Month = $month
                    Maker = $maker
                    'Vehicle Class' = $class
                    'Registration Count / Value' = $count
                })
                Add-Count $makerMonths "$year`t$month`t$maker" $count
                Add-Count $makerClasses "$year`t$maker`t$class" $count
                Add-Count $monthClasses "$monthKey`t$class" $count
                Add-Count $monthTotals $monthKey $count
            }
        }
    }
    foreach ($column in $baseline.Dimensions) {
        $date = [datetime]::ParseExact($column, 'yyyy-MMM', [System.Globalization.CultureInfo]::InvariantCulture)
        [void]$coveredMonths.Add($date.ToString('yyyy-MM'))
    }
    foreach ($record in $baseline.Records.Values) {
        foreach ($column in $baseline.Dimensions) {
            $date = [datetime]::ParseExact($column, 'yyyy-MMM', [System.Globalization.CultureInfo]::InvariantCulture)
            Assert-Count $makerMonths "$year`t$($date.Month)`t$($record.Maker)" $record.$column 'maker-month'
        }
    }
    foreach ($record in $classTotals.Records.Values) {
        foreach ($class in $classTotals.Dimensions) {
            Assert-Count $makerClasses "$year`t$($record.Maker)`t$class" $record.$class 'maker-class'
        }
    }
}
$monthlyClasses = $tables['month-wise-vehicle-class.csv']
foreach ($record in $monthlyClasses.Records.Values) {
    foreach ($class in $monthlyClasses.Dimensions) {
        Assert-Count $monthClasses "$($record.Month)`t$class" $record.$class 'month-class'
    }
}
foreach ($table in $tables.Values | Where-Object { $_.KeyColumn -eq 'Month' }) {
    $baseline = $tables['maker_monthWise_2024_all_records.csv']
    if ($table.Period -ne '2024-2026' -or $table.Filters -cne $baseline.Filters -or $table.Geography -cne $baseline.Geography) { throw "Monthly export scope mismatch: $($table.File)" }
    foreach ($monthKey in $coveredMonths) {
        if (-not $table.Records.ContainsKey($monthKey)) { throw "Missing observed month: $($table.File) / $monthKey" }
    }
    foreach ($record in $table.Records.Values) {
        if (-not $coveredMonths.Contains($record.Month) -and -not ($table.File -eq 'month-wise-consolidated.csv' -and $record.Month -eq '2026-12' -and $record.($table.TotalColumn) -eq 0)) {
            throw "Unexpected monthly period: $($table.File) / $($record.Month)"
        }
        Assert-Count $monthTotals $record.Month $record.($table.TotalColumn) $table.File
    }
}

$outputRows = @($records | Sort-Object Year, Month, Maker, 'Vehicle Class' | ForEach-Object {
    $record = $_
    $year = $record.Year
    $maker = $record.Maker
    $monthKey = '{0}-{1:D2}' -f $year, $record.Month
    $rto = Get-Attribute $year $maker $monthKey 'rtoName'
    $rtoCode = ''
    $rtoMatch = [regex]::Match($rto, '^(.*) - ([A-Z]{2}[0-9]+)$')
    if ($rtoMatch.Success) {
        $rto = $rtoMatch.Groups[1].Value
        $rtoCode = $rtoMatch.Groups[2].Value
    }
    [pscustomobject][ordered]@{
        Year = $year
        Month = $record.Month
        Maker = $maker
        'Vehicle Class' = $record.'Vehicle Class'
        'Registration Count / Value' = $record.'Registration Count / Value'
        State = Get-Attribute $year $maker $monthKey 'stateCode'
        RTO = $rto
        'RTO Code' = $rtoCode
        'Vehicle Class Type' = Get-Attribute $year $maker $monthKey 'vehicleType' 'month-wise-vehicle-type.csv'
        'Fuel Type' = Get-Attribute $year $maker $monthKey 'vehicleFuel' 'month-wise-fuel.csv'
        Model = ''
        'Battery capacity' = ''
        'Vehicle category' = Get-Attribute $year $maker $monthKey 'vehicleCategoryDescription' 'month-wise-vehicle-category.csv'
    }
})
$expectedColumns = @('Year', 'Month', 'Maker', 'Vehicle Class', 'Registration Count / Value', 'State', 'RTO', 'RTO Code', 'Vehicle Class Type', 'Fuel Type', 'Model', 'Battery capacity', 'Vehicle category')
$outputPath = Join-Path $OutputDirectory '01_VAHAN_RAW.csv'
$outputRows | Export-Csv -LiteralPath $outputPath -NoTypeInformation -Encoding UTF8
$roundTrip = @(Import-Csv -LiteralPath $outputPath)
if ($roundTrip.Count -ne $outputRows.Count -or ($roundTrip[0].PSObject.Properties.Name -join '|') -cne ($expectedColumns -join '|')) { throw 'Output CSV schema or row count mismatch' }
for ($rowIndex = 0; $rowIndex -lt $outputRows.Count; $rowIndex++) {
    foreach ($column in $expectedColumns) {
        if ([string]$roundTrip[$rowIndex].$column -cne [string]$outputRows[$rowIndex].$column) { throw "Output CSV round-trip mismatch: row $rowIndex / $column" }
    }
}

$report = [System.Collections.Generic.List[string]]::new()
$report.Add('# VAHAN Consolidation Notes')
$report.Add('')
$report.Add("Output: 01_VAHAN_RAW.csv. Audited $($tables.Count) input CSVs, including $sourceCount class-specific maker-by-month exports.")
$report.Add('')
$report.Add('## Coverage and Validation')
$report.Add('')
$report.Add('One row per Year + Month + Maker + Vehicle Class with a strictly positive registration count. Month is numeric (1-12).')
$report.Add('')
$report.Add('| Year | Output rows | Registrations | Coverage |')
$report.Add('| --- | ---: | ---: | --- |')
$totalCount = 0L
foreach ($group in $outputRows | Group-Object Year | Sort-Object Name) {
    $count = [long]($group.Group | Measure-Object -Property 'Registration Count / Value' -Sum).Sum
    $totalCount += $count
    $coverage = if ($group.Name -eq '2026') { 'January-November' } else { 'January-December' }
    $report.Add("| $($group.Name) | $($group.Count) | $count | $coverage |")
}
$report.Add("| Total | $($outputRows.Count) | $totalCount | |")
$report.Add('')
$report.Add('- All source numeric counts, row totals, footer totals and within-table keys were validated.')
$report.Add('- Original maker-year totals and maker identities match across all annual pivots. Fuel, class, category, owner type and vehicle type totals also match their monthly pivots.')
$report.Add('- Class-specific exports use identical periods, geographic coverage and filters except for the intentionally narrowed class filter.')
$report.Add('- Output counts reconcile to every original maker-month, maker-year-class and month-class count, and every monthly summary total. Output keys are unique.')
$report.Add('- Total rows/columns are validation controls, never observations. The seven class slices are appended; other pivots are not appended or joined many-to-many.')
$report.Add('- The saved CSV was read back and every cell and column name was verified against the generated records.')
$report.Add('')
$report.Add('## Field Mappings')
$report.Add('')
$report.Add('| Output field | Source and rule |')
$report.Add('| --- | --- |')
$report.Add('| Year, Month | Parsed from each class-specific monthly header (for example, 2024-Jan). Manufacturing year is not used as registration year. |')
$report.Add('| Maker | Exact source Maker string, matched within registration year. No fuzzy matching or manufacturer aliases. |')
$report.Add('| Vehicle Class | Single class in the export metadata, checked against its filename and original class totals. |')
$report.Add('| Registration Count / Value | Original integer monthly cell value. This is a registration count, not a monetary value. |')
$report.Add('| State | State-name column in the annual maker-state pivot, only when the maker has one positive state for that year. |')
$report.Add('| RTO, RTO Code | Annual maker-RTO pivot, only when one RTO has a positive count for that maker-year. The name and code are split at the final ` - CODE` suffix; code spelling is preserved (for example, KA5 is not padded). |')
$report.Add('| Vehicle Class Type | Source Vehicle Type, currently commercial, corroborated by the Transport metadata filter. This is a documented proxy; no separate Class Type field exists in the exports. |')
$report.Add('| Fuel Type, Vehicle category | Intersect positive values in the annual maker pivot and the corresponding all-maker monthly pivot. Populate only if exactly one value remains. Otherwise leave blank. No proportional allocation or dominant-value selection. |')
$report.Add('| Model, Battery capacity | Absent from the supplied sources; left blank. |')
$report.Add('')
$report.Add('## Missing Optional Values')
$report.Add('')
$report.Add('Blank means unavailable, mixed, or not uniquely assignable at this row granularity; it never means zero or not applicable. Coverage below counts rows, not registration volumes.')
$report.Add('')
$report.Add('| Optional field | Populated rows | Blank rows |')
$report.Add('| --- | ---: | ---: |')
foreach ($column in $expectedColumns | Select-Object -Skip 5) {
    $populated = @($outputRows | Where-Object { -not [string]::IsNullOrEmpty([string]$_.$column) }).Count
    $report.Add("| $column | $populated | $($outputRows.Count - $populated) |")
}
$report.Add('')
$report.Add('## Limitations')
$report.Add('')
$report.Add('- Scope remains the supplied Transport/commercial, filtered two-wheeler population. Positive fuel counts are ELECTRIC(BOV) and PURE EV. This is not a complete all-fuel or all-two-wheeler market dataset.')
$report.Add('- Coverage ends in November 2026. December 2026 is absent from the output; the zero placeholder found only in month-wise-consolidated.csv is not treated as an observed month.')
$report.Add('- The extraction timestamp is not supplied. November 2026 should not be assumed complete; as of the stated analysis date (2026-11-06), the month is still in progress.')
$report.Add('- Explicit zero-count source cells are omitted. No missing cells or future months are synthesized. Absence of an output row alone does not establish a zero outside the verified source coverage.')
$report.Add('- HERO MOTOCORP LTD has one TWO WHEELER(NT) registration in the 2025 category pivot, and October 2025 has the corresponding monthly exception despite the Transport selection. The category for the ambiguous HERO October row remains blank; the source classification needs validation.')
$report.Add('- Vehicle category labels do not distinguish scooter from motorcycle. Multi-state, multi-RTO and mixed-fuel registrations are not disaggregated without joint evidence.')
$report.Add('- No additional data is needed for the five essential fields. Completing optional splits would require joint maker-month-class exports filtered further by fuel or geography, or equivalent detailed records. Model and battery capacity need a separate compatible source.')
$report.Add('')
$report.Add('## Reproduce')
$report.Add('')
$report.Add('Run `& .\build_vahan.ps1` in this directory. The script revalidates the supplied inputs in source_data and regenerates the CSV and this report. Source CSVs are never modified.')
$reportPath = Join-Path $OutputDirectory '01_VAHAN_RAW_notes.md'
[System.IO.File]::WriteAllLines($reportPath, $report, [System.Text.UTF8Encoding]::new($false))
Write-Output "Validated $sourceCount class-specific exports and $($tables.Count) source tables."
$outputRows | Group-Object Year | ForEach-Object {
    [pscustomobject]@{ Year = $_.Name; Rows = $_.Count; Registrations = ($_.Group | Measure-Object -Property 'Registration Count / Value' -Sum).Sum }
} | Format-Table -AutoSize
Write-Output "Created $outputPath with $($outputRows.Count) unique rows and $totalCount registrations."
Write-Output "Created $reportPath."