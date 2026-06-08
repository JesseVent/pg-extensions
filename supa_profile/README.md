# supa_profile - PostgreSQL Database Table & Column Profiler

`supa_profile` is a relocatable, pure SQL PostgreSQL **Trusted Language Extension (TLE)** designed for native table and column-level statistical profiling. It introspects schema metadata, dynamically constructs profiling queries, and compiles a comprehensive statistical report (including counts, nullability, distinctness, min/max, string length distributions, averages, medians, percentiles, and frequent value distributions) returned directly as a single structured JSONB document.

The JSONB output format is fully compatible with the **`ProfilingResult`** TypeScript interface used by frontend profiling dashboards.

---

## 🚀 Installation

### 1. Enable TLE Support
`supa_profile` runs as a Trusted Language Extension and requires the `pg_tle` extension to be enabled:

```sql
CREATE EXTENSION IF NOT EXISTS "pg_tle";
```

### 2. Installing from database.dev

Using the [dbdev CLI](https://supabase.github.io/dbdev):

```bash
dbdev add -o ./migrations -s extensions -v 1.0.0 package -n "jvent@supa_profile"
```

This generates a migration script to load the TLE. Apply the migration, then enable the extension:

```sql
CREATE EXTENSION "jvent@supa_profile" VERSION '1.0.0' SCHEMA supa_profile;
```

---

## 🛠️ API Reference

### 1. Profile Table
Introspects and profiles a physical table, view, or materialized view.
* **Function:** `supa_profile.profile_table(target_table regclass, options jsonb DEFAULT '{}') RETURNS jsonb`
* **Options Parameter (`options`):**
  A JSON object supporting the following parameters:
  - `scan_field_values` (boolean, default: `true`): Scan column values to compute top value frequency distributions.
  - `min_cell_count` (int, default: `5`): Minimum occurrence count of a value to include it in the value distribution list.
  - `max_distinct_values` (int, default: `100`): Maximum distinct values returned per column in the value distribution list.
  - `rows_per_table` (int, default: `0` = unlimited): Maximum rows to scan. If greater than zero, it wraps the source in a sampled subquery (`LIMIT N`).
  - `calculate_numeric_stats` (boolean, default: `true`): Compute average, median, 90th percentile, and 99th percentile for numeric fields.

* **Example:**
  ```sql
  SELECT supa_profile.profile_table(
      'public.users'::regclass,
      '{"rows_per_table": 10000, "min_cell_count": 10}'::jsonb
  );
  ```

---

## 📊 Output Schema (JSONB)

The function returns a JSONB object containing:
- `tableStats`: Table name, row count, column count.
- `fields`: Array of column-level statistics.
- `values`: Value frequency distribution array.
- `profiledAt`: Timestamp in UTC.
- `durationMs`: Total duration of the profiling process.
- `queryMode`: Current query mode (`NORMAL` or `FAST` for sampled scans).

### Field Properties:
| Property | Type | Description |
|---|---|---|
| `columnName` | `text` | Column identifier |
| `dataType` | `text` | Column type format |
| `nullable` | `boolean` | True if nulls are allowed |
| `nonNullCount` | `bigint` | Total count of non-null cells |
| `nullCount` | `bigint` | Total count of null cells |
| `distinctCount` | `bigint` | Total unique value count |
| `minValue` | `text` | Minimum value (omitted for JSON/bytes/arrays) |
| `maxValue` | `text` | Maximum value (omitted for JSON/bytes/arrays) |
| `avgValue` | `numeric` | Average value (numeric columns only) |
| `median` | `numeric` | Median value / P50 (numeric columns only) |
| `p90` | `numeric` | 90th percentile value (numeric columns only) |
| `p99` | `numeric` | 99th percentile value (numeric columns only) |
| `avgLength` | `numeric` | Average string length of text representation |
| `maxLength` | `bigint` | Maximum string length of text representation |
| `mode` | `text` | Most frequent value (omitted if `scan_field_values` is false) |
| `pattern` | `text` | Inferred regex pattern for type verification |

---

## 📖 Example Walkthrough

### 1. Create Sample Table
```sql
CREATE TABLE public.customers (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    age INT,
    country VARCHAR(3) DEFAULT 'USA',
    signup_date DATE
);

INSERT INTO public.customers (name, age, country, signup_date) VALUES
('Alice', 25, 'USA', '2025-01-10'),
('Bob', 30, 'USA', '2025-02-15'),
('Charlie', 45, 'CAN', '2024-11-20'),
('Diana', 25, 'USA', '2025-03-01'),
('Ethan', NULL, 'GBR', NULL);
```

### 2. Profile the Table
```sql
SELECT jsonb_pretty(supa_profile.profile_table('public.customers'::regclass, '{"min_cell_count": 1}'::jsonb));
```

### 3. Example JSONB Output
```json
{
  "fields": [
    {
      "mode": "",
      "pattern": "-?\\d+",
      "dataType": "integer",
      "nullable": false,
      "nullCount": 0,
      "avgLength": 1.0,
      "columnName": "id",
      "distinctCount": 5,
      "maxLength": 1,
      "nonNullCount": 5,
      "tableName": "public.customers",
      "avgValue": 3.0,
      "median": 3.0,
      "p90": 5.0,
      "p99": 5.0,
      "minValue": "1",
      "maxValue": "5"
    },
    {
      "mode": "",
      "pattern": ".*",
      "dataType": "text",
      "nullable": false,
      "nullCount": 0,
      "avgLength": 4.6,
      "columnName": "name",
      "distinctCount": 5,
      "maxLength": 7,
      "nonNullCount": 5,
      "tableName": "public.customers",
      "minValue": "Alice",
      "maxValue": "Ethan"
    },
    {
      "mode": "25",
      "pattern": "-?\\d+",
      "dataType": "integer",
      "nullable": true,
      "nullCount": 1,
      "avgLength": 1.6,
      "columnName": "age",
      "distinctCount": 3,
      "maxLength": 2,
      "nonNullCount": 4,
      "tableName": "public.customers",
      "avgValue": 31.25,
      "median": 30.0,
      "p90": 45.0,
      "p99": 45.0,
      "minValue": "25",
      "maxValue": "45"
    },
    {
      "mode": "USA",
      "pattern": ".*",
      "dataType": "character varying(3)",
      "nullable": true,
      "nullCount": 0,
      "avgLength": 3.0,
      "columnName": "country",
      "distinctCount": 3,
      "maxLength": 3,
      "nonNullCount": 5,
      "tableName": "public.customers",
      "minValue": "CAN",
      "maxValue": "USA"
    }
  ],
  "values": [
    {
      "value": "25",
      "percent": 0.4000,
      "frequency": 2,
      "columnName": "age"
    },
    {
      "value": "USA",
      "percent": 0.6000,
      "frequency": 3,
      "columnName": "country"
    }
  ],
  "queryMode": "NORMAL",
  "durationMs": 4.32,
  "profiledAt": "2026-06-08T18:00:00Z",
  "tableStats": {
    "rowCount": 5,
    "selected": false,
    "tableName": "public.customers",
    "columnCount": 5
  }
}
```

---

## 🛡️ License
MIT License. Feel free to use and distribute.
