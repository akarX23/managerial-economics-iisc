# VAHAN Consolidation Notes

Output: 01_VAHAN_RAW.csv. Audited 40 input CSVs, including 7 class-specific maker-by-month exports.

## Coverage and Validation

One row per Year + Month + Maker + Vehicle Class with a strictly positive registration count. Month is numeric (1-12).

| Year | Output rows | Registrations | Coverage |
| --- | ---: | ---: | --- |
| 2024 | 90 | 7591 | January-December |
| 2025 | 121 | 11246 | January-December |
| 2026 | 151 | 21120 | January-November |
| Total | 362 | 39957 | |

- All source numeric counts, row totals, footer totals and within-table keys were validated.
- Original maker-year totals and maker identities match across all annual pivots. Fuel, class, category, owner type and vehicle type totals also match their monthly pivots.
- Class-specific exports use identical periods, geographic coverage and filters except for the intentionally narrowed class filter.
- Output counts reconcile to every original maker-month, maker-year-class and month-class count, and every monthly summary total. Output keys are unique.
- Total rows/columns are validation controls, never observations. The seven class slices are appended; other pivots are not appended or joined many-to-many.
- The saved CSV was read back and every cell and column name was verified against the generated records.

## Field Mappings

| Output field | Source and rule |
| --- | --- |
| Year, Month | Parsed from each class-specific monthly header (for example, 2024-Jan). Manufacturing year is not used as registration year. |
| Maker | Exact source Maker string, matched within registration year. No fuzzy matching or manufacturer aliases. |
| Vehicle Class | Single class in the export metadata, checked against its filename and original class totals. |
| Registration Count / Value | Original integer monthly cell value. This is a registration count, not a monetary value. |
| State | State-name column in the annual maker-state pivot, only when the maker has one positive state for that year. |
| RTO, RTO Code | Annual maker-RTO pivot, only when one RTO has a positive count for that maker-year. The name and code are split at the final ` - CODE` suffix; code spelling is preserved (for example, KA5 is not padded). |
| Vehicle Class Type | Source Vehicle Type, currently commercial, corroborated by the Transport metadata filter. This is a documented proxy; no separate Class Type field exists in the exports. |
| Fuel Type, Vehicle category | Intersect positive values in the annual maker pivot and the corresponding all-maker monthly pivot. Populate only if exactly one value remains. Otherwise leave blank. No proportional allocation or dominant-value selection. |
| Model, Battery capacity | Absent from the supplied sources; left blank. |

## Missing Optional Values

Blank means unavailable, mixed, or not uniquely assignable at this row granularity; it never means zero or not applicable. Coverage below counts rows, not registration volumes.

| Optional field | Populated rows | Blank rows |
| --- | ---: | ---: |
| State | 107 | 255 |
| RTO | 66 | 296 |
| RTO Code | 66 | 296 |
| Vehicle Class Type | 362 | 0 |
| Fuel Type | 184 | 178 |
| Model | 0 | 362 |
| Battery capacity | 0 | 362 |
| Vehicle category | 361 | 1 |

## Limitations

- Scope remains the supplied Transport/commercial, filtered two-wheeler population. Positive fuel counts are ELECTRIC(BOV) and PURE EV. This is not a complete all-fuel or all-two-wheeler market dataset.
- Coverage ends in November 2026. December 2026 is absent from the output; the zero placeholder found only in month-wise-consolidated.csv is not treated as an observed month.
- The extraction timestamp is not supplied. November 2026 should not be assumed complete; as of the stated analysis date (2026-11-06), the month is still in progress.
- Explicit zero-count source cells are omitted. No missing cells or future months are synthesized. Absence of an output row alone does not establish a zero outside the verified source coverage.
- HERO MOTOCORP LTD has one TWO WHEELER(NT) registration in the 2025 category pivot, and October 2025 has the corresponding monthly exception despite the Transport selection. The category for the ambiguous HERO October row remains blank; the source classification needs validation.
- Vehicle category labels do not distinguish scooter from motorcycle. Multi-state, multi-RTO and mixed-fuel registrations are not disaggregated without joint evidence.
- No additional data is needed for the five essential fields. Completing optional splits would require joint maker-month-class exports filtered further by fuel or geography, or equivalent detailed records. Model and battery capacity need a separate compatible source.

## Reproduce

Run `& .\build_vahan.ps1` in this directory. The script revalidates the supplied inputs in source_data and regenerates the CSV and this report. Source CSVs are never modified.
