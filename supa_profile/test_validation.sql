-- =====================================================================
-- SUPA_PROFILE EXTENSION VALIDATION TEST SCRIPT
-- Run this script to verify the correctness of the profiling functions.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------
-- 1. Loading extension schema and functions...
-- ---------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS supa_profile;

-- Copy of helper functions for standalone execution verification
CREATE OR REPLACE FUNCTION supa_profile.infer_pattern(data_type text)
RETURNS text AS $$
DECLARE
    t text := upper(data_type);
BEGIN
    IF t LIKE '%DATE%' THEN RETURN 'YYYY-MM-DD'; END IF;
    IF t LIKE '%TIME%' THEN RETURN 'HH:MM:SS'; END IF;
    IF t LIKE '%INT%' THEN RETURN '-?\d+'; END IF;
    IF t LIKE '%FLOAT%' OR t LIKE '%NUMERIC%' OR t LIKE '%DECIMAL%' OR t LIKE '%DOUBLE%' OR t LIKE '%REAL%' THEN 
        RETURN '-?\d+\.?\d*'; 
    END IF;
    RETURN '.*';
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION supa_profile.profile_table(
    target_table regclass,
    options jsonb DEFAULT '{}'
)
RETURNS jsonb AS $$
DECLARE
    -- Options
    scan_field_values boolean;
    min_cell_count int;
    max_distinct_values int;
    rows_per_table int;
    calculate_numeric_stats boolean;

    -- Execution metadata
    start_time timestamptz;
    duration_ms numeric;
    total_rows bigint;
    column_count int;
    
    -- Table/Schema name
    full_table_name text;
    from_clause text;
    
    -- Column loop
    col record;
    is_numeric boolean;
    skip_min_max boolean;
    
    -- SQL Construction
    select_exprs text := '';
    query_str text;
    result_row record;
    result_json jsonb;
    
    -- Arrays
    fields_array jsonb := '[]'::jsonb;
    values_array jsonb := '[]'::jsonb;
    
    -- Temp vars for each column
    non_null_count bigint;
    distinct_count bigint;
    min_val text;
    max_val text;
    avg_len numeric;
    max_len bigint;
    avg_val numeric;
    median_val numeric;
    p90_val numeric;
    p99_val numeric;
    
    -- Mode and Value Distribution
    val_query text;
    val_rec record;
    val_obj jsonb;
    mode_val text;
    mode_found boolean;
    field_obj jsonb;
BEGIN
    start_time := clock_timestamp();
    full_table_name := target_table::text;

    -- Ensure options is not null
    options := coalesce(options, '{}'::jsonb);

    -- Parse options with defaults
    scan_field_values := coalesce((options ->> 'scan_field_values')::boolean, true);
    min_cell_count := coalesce((options ->> 'min_cell_count')::int, 5);
    max_distinct_values := coalesce((options ->> 'max_distinct_values')::int, 100);
    rows_per_table := coalesce((options ->> 'rows_per_table')::int, 0);
    calculate_numeric_stats := coalesce((options ->> 'calculate_numeric_stats')::boolean, true);

    -- Build FROM clause with optional sampling/limit
    IF rows_per_table > 0 THEN
        from_clause := '(SELECT * FROM ' || full_table_name || ' LIMIT ' || rows_per_table || ') AS sampled_table';
    ELSE
        from_clause := full_table_name;
    END IF;

    -- Retrieve column count
    SELECT COUNT(*)::int INTO column_count
    FROM pg_attribute
    WHERE attrelid = target_table AND attnum > 0 AND NOT attisdropped;

    -- Build SELECT expressions for column stats
    FOR col IN
        SELECT 
            attname AS column_name,
            format_type(atttypid, atttypmod) AS data_type,
            NOT attnotnull AS is_nullable
        FROM pg_attribute
        WHERE attrelid = target_table AND attnum > 0 AND NOT attisdropped
        ORDER BY attnum
    LOOP
        -- Determine if type is numeric
        is_numeric := (col.data_type IN ('smallint', 'integer', 'bigint', 'decimal', 'numeric', 'real', 'double precision') 
                       OR col.data_type ~* 'int|numeric|decimal|real|double|float|number');

        -- Determine if type does not support MIN/MAX
        skip_min_max := (col.data_type ~* '\[\]|json|jsonb|bytea|xml|geometry|geography|box|circle|line|lseg|path|point|polygon|xid|cid|oid|tid|txid_snapshot');

        -- Basic column stats
        select_exprs := select_exprs || ', COUNT(' || quote_ident(col.column_name) || ') AS ' || quote_ident(col.column_name || '__non_null');
        select_exprs := select_exprs || ', COUNT(DISTINCT ' || quote_ident(col.column_name) || ') AS ' || quote_ident(col.column_name || '__distinct');

        -- MIN/MAX
        IF skip_min_max THEN
            select_exprs := select_exprs || ', NULL::text AS ' || quote_ident(col.column_name || '__min');
            select_exprs := select_exprs || ', NULL::text AS ' || quote_ident(col.column_name || '__max');
        ELSE
            select_exprs := select_exprs || ', MIN(' || quote_ident(col.column_name) || ')::text AS ' || quote_ident(col.column_name || '__min');
            select_exprs := select_exprs || ', MAX(' || quote_ident(col.column_name) || ')::text AS ' || quote_ident(col.column_name || '__max');
        END IF;

        -- Avg and Max string length
        select_exprs := select_exprs || ', AVG(length(' || quote_ident(col.column_name) || '::text))::numeric AS ' || quote_ident(col.column_name || '__avg_len');
        select_exprs := select_exprs || ', MAX(length(' || quote_ident(col.column_name) || '::text))::bigint AS ' || quote_ident(col.column_name || '__max_len');

        -- Numeric stats (AVG, MEDIAN, P90, P99)
        IF calculate_numeric_stats AND is_numeric THEN
            select_exprs := select_exprs || ', AVG(' || quote_ident(col.column_name) || ')::numeric AS ' || quote_ident(col.column_name || '__avg');
            select_exprs := select_exprs || ', percentile_disc(0.5) WITHIN GROUP (ORDER BY ' || quote_ident(col.column_name) || ')::numeric AS ' || quote_ident(col.column_name || '__median');
            select_exprs := select_exprs || ', percentile_disc(0.9) WITHIN GROUP (ORDER BY ' || quote_ident(col.column_name) || ')::numeric AS ' || quote_ident(col.column_name || '__p90');
            select_exprs := select_exprs || ', percentile_disc(0.99) WITHIN GROUP (ORDER BY ' || quote_ident(col.column_name) || ')::numeric AS ' || quote_ident(col.column_name || '__p99');
        ELSE
            select_exprs := select_exprs || ', NULL::numeric AS ' || quote_ident(col.column_name || '__avg');
            select_exprs := select_exprs || ', NULL::numeric AS ' || quote_ident(col.column_name || '__median');
            select_exprs := select_exprs || ', NULL::numeric AS ' || quote_ident(col.column_name || '__p90');
            select_exprs := select_exprs || ', NULL::numeric AS ' || quote_ident(col.column_name || '__p99');
        END IF;
    END LOOP;

    -- Execute main statistics query
    query_str := 'SELECT COUNT(*) AS total_rows' || select_exprs || ' FROM ' || from_clause;
    EXECUTE query_str INTO result_row;
    result_json := to_jsonb(result_row);
    total_rows := (result_json ->> 'total_rows')::bigint;

    -- Execute value distribution query per column if enabled
    IF scan_field_values AND total_rows > 0 THEN
        FOR col IN
            SELECT attname AS column_name
            FROM pg_attribute
            WHERE attrelid = target_table AND attnum > 0 AND NOT attisdropped
            ORDER BY attnum
        LOOP
            val_query := 'SELECT ' || 
                         quote_literal(col.column_name) || ' AS column_name, ' || 
                         'coalesce(' || quote_ident(col.column_name) || '::text, ''NULL'') AS value, ' || 
                         'COUNT(*) AS frequency ' ||
                         'FROM ' || from_clause || ' ' ||
                         'WHERE ' || quote_ident(col.column_name) || ' IS NOT NULL ' ||
                         'GROUP BY ' || quote_ident(col.column_name) || '::text ' ||
                         'HAVING COUNT(*) >= ' || min_cell_count || ' ' ||
                         'ORDER BY COUNT(*) DESC ' ||
                         'LIMIT ' || max_distinct_values;

            FOR val_rec IN EXECUTE val_query LOOP
                val_obj := jsonb_build_object(
                    'columnName', val_rec.column_name,
                    'value', val_rec.value,
                    'frequency', val_rec.frequency,
                    'percent', CASE WHEN total_rows > 0 THEN (val_rec.frequency::numeric / total_rows)::numeric(10,4) ELSE 0 END
                );
                values_array := values_array || jsonb_build_array(val_obj);
            END LOOP;
        END LOOP;
    END IF;

    -- Build final fields array
    FOR col IN
        SELECT 
            attname AS column_name,
            format_type(atttypid, atttypmod) AS data_type,
            NOT attnotnull AS is_nullable
        FROM pg_attribute
        WHERE attrelid = target_table AND attnum > 0 AND NOT attisdropped
        ORDER BY attnum
    LOOP
        non_null_count := (result_json ->> (col.column_name || '__non_null'))::bigint;
        distinct_count := (result_json ->> (col.column_name || '__distinct'))::bigint;
        min_val := result_json ->> (col.column_name || '__min');
        max_val := result_json ->> (col.column_name || '__max');
        avg_len := (result_json ->> (col.column_name || '__avg_len'))::numeric;
        max_len := (result_json ->> (col.column_name || '__max_len'))::bigint;
        avg_val := (result_json ->> (col.column_name || '__avg'))::numeric;
        median_val := (result_json ->> (col.column_name || '__median'))::numeric;
        p90_val := (result_json ->> (col.column_name || '__p90'))::numeric;
        p99_val := (result_json ->> (col.column_name || '__p99'))::numeric;

        -- Find mode for this column if we scanned values
        mode_val := '';
        IF scan_field_values THEN
            -- Find the first value in values_array for this column
            -- Since values_array is sorted by frequency DESC, the first one is the mode
            DECLARE
                temp_val jsonb;
            BEGIN
                FOR temp_val IN SELECT * FROM jsonb_array_elements(values_array) LOOP
                    IF temp_val ->> 'columnName' = col.column_name THEN
                        mode_val := temp_val ->> 'value';
                        EXIT;
                    END IF;
                END LOOP;
            END;
        END IF;

        -- Construct field profile object matching FieldProfile interface
        field_obj := jsonb_build_object(
            'tableName', full_table_name,
            'columnName', col.column_name,
            'dataType', col.data_type,
            'nullable', col.is_nullable,
            'nonNullCount', non_null_count,
            'nullCount', total_rows - non_null_count,
            'distinctCount', distinct_count,
            'avgLength', coalesce(avg_len, 0),
            'maxLength', coalesce(max_len, 0),
            'mode', mode_val,
            'pattern', supa_profile.infer_pattern(col.data_type)
        );

        -- Add optional numeric and min/max stats
        IF min_val IS NOT NULL THEN
            field_obj := field_obj || jsonb_build_object('minValue', min_val);
        END IF;
        IF max_val IS NOT NULL THEN
            field_obj := field_obj || jsonb_build_object('maxValue', max_val);
        END IF;
        IF avg_val IS NOT NULL THEN
            field_obj := field_obj || jsonb_build_object('avgValue', avg_val);
        END IF;
        IF median_val IS NOT NULL THEN
            field_obj := field_obj || jsonb_build_object('median', median_val);
        END IF;
        IF p90_val IS NOT NULL THEN
            field_obj := field_obj || jsonb_build_object('p90', p90_val);
        END IF;
        IF p99_val IS NOT NULL THEN
            field_obj := field_obj || jsonb_build_object('p99', p99_val);
        END IF;

        fields_array := fields_array || jsonb_build_array(field_obj);
    END LOOP;

    duration_ms := EXTRACT(EPOCH FROM (clock_timestamp() - start_time)) * 1000;

    -- Return full result matching ProfilingResult interface
    RETURN jsonb_build_object(
        'tableStats', jsonb_build_object(
            'tableName', full_table_name,
            'rowCount', total_rows,
            'columnCount', column_count,
            'selected', false
        ),
        'fields', fields_array,
        'values', values_array,
        'profiledAt', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'durationMs', round(duration_ms, 2),
        'queryMode', CASE WHEN rows_per_table > 0 THEN 'FAST' ELSE 'NORMAL' END
    );
END;
$$ LANGUAGE plpgsql VOLATILE STRICT;

-- ---------------------------------------------------------
-- 2. Create mock tables and populate data...
-- ---------------------------------------------------------

CREATE TEMP TABLE mock_users (
    id serial PRIMARY KEY,
    username text NOT NULL,
    age int,
    salary numeric(10, 2),
    signup_date date,
    extra_info jsonb,
    tags text[]
);

INSERT INTO mock_users (username, age, salary, signup_date, extra_info, tags) VALUES
('alice', 25, 80000.00, '2025-01-10'::date, '{"city": "NY"}'::jsonb, ARRAY['admin', 'staff']),
('bob', 30, 95000.00, '2025-02-15'::date, '{"city": "SF"}'::jsonb, ARRAY['staff']),
('charlie', 45, 120000.50, '2024-11-20'::date, '{"city": "NY"}'::jsonb, ARRAY['admin']),
('diana', 25, 80000.00, '2025-03-01'::date, NULL::jsonb, ARRAY['user']),
('diana', 25, NULL::numeric, NULL::date, '{"city": "LA"}'::jsonb, NULL::text[]);

-- ---------------------------------------------------------
-- 3. Execute unit tests...
-- ---------------------------------------------------------
DO $$
DECLARE
    res jsonb;
    fields jsonb;
    vals jsonb;
    f record;
    v record;
BEGIN
    -- Profile the mock table with default options
    res := supa_profile.profile_table('mock_users'::regclass, '{"min_cell_count": 2}'::jsonb);

    -- Verify tableStats
    ASSERT res -> 'tableStats' ->> 'tableName' = 'mock_users', 'Table stats name mismatch';
    ASSERT (res -> 'tableStats' ->> 'rowCount')::int = 5, 'Table stats row count mismatch';
    ASSERT (res -> 'tableStats' ->> 'columnCount')::int = 7, 'Table stats column count mismatch';
    
    fields := res -> 'fields';
    vals := res -> 'values';

    -- Loop through fields and check basic validation
    FOR f IN SELECT * FROM jsonb_to_recordset(fields) AS (
        "columnName" text, "dataType" text, "nullable" boolean, 
        "nonNullCount" int, "nullCount" int, "distinctCount" int, 
        "minValue" text, "maxValue" text, "avgValue" numeric, 
        "median" numeric, "mode" text, "pattern" text
    ) LOOP
        IF f."columnName" = 'id' THEN
            ASSERT f."nullable" = false, 'id should not be nullable';
            ASSERT f."nonNullCount" = 5, 'id non-null count mismatch';
            ASSERT f."distinctCount" = 5, 'id distinct count mismatch';
            ASSERT f."minValue" = '1', 'id min mismatch';
            ASSERT f."maxValue" = '5', 'id max mismatch';
            ASSERT f."avgValue" = 3.00, 'id avg mismatch';
            ASSERT f."median" = 3.00, 'id median mismatch';
            ASSERT f."pattern" = '-?\d+', 'id pattern mismatch';
        ELSIF f."columnName" = 'username' THEN
            ASSERT f."nullable" = false, 'username should not be nullable';
            ASSERT f."nonNullCount" = 5, 'username non-null count mismatch';
            ASSERT f."distinctCount" = 4, 'username distinct count mismatch';
            ASSERT f."minValue" = 'alice', 'username min mismatch';
            ASSERT f."maxValue" = 'diana', 'username max mismatch';
            ASSERT f."mode" = 'diana', 'username mode mismatch (should be diana, frequency = 2)';
        ELSIF f."columnName" = 'age' THEN
            ASSERT f."nullable" = true, 'age should be nullable';
            ASSERT f."nonNullCount" = 5, 'age non-null count mismatch';
            ASSERT f."distinctCount" = 3, 'age distinct count mismatch';
            ASSERT f."minValue" = '25', 'age min mismatch';
            ASSERT f."maxValue" = '45', 'age max mismatch';
            ASSERT f."median" = 25.00, 'age median mismatch';
            ASSERT f."mode" = '25', 'age mode mismatch (frequency = 3)';
        ELSIF f."columnName" = 'salary' THEN
            ASSERT f."nullable" = true, 'salary should be nullable';
            ASSERT f."nonNullCount" = 4, 'salary non-null count mismatch';
            ASSERT f."nullCount" = 1, 'salary null count mismatch';
            ASSERT f."minValue" = '80000.00', 'salary min mismatch';
            ASSERT f."maxValue" = '120000.50', 'salary max mismatch';
        ELSIF f."columnName" = 'extra_info' THEN
            -- Verify that skipped types like jsonb have null min/max but non-null and distinct counts
            ASSERT f."minValue" IS NULL, 'jsonb should not have min';
            ASSERT f."maxValue" IS NULL, 'jsonb should not have max';
            ASSERT f."nonNullCount" = 4, 'jsonb non-null count mismatch';
            ASSERT f."distinctCount" = 3, 'jsonb distinct count mismatch';
        END IF;
    END LOOP;

    -- Verify value distribution (we filtered with min_cell_count = 2)
    -- Values expected to be frequent: age=25 (freq=3), salary=80000.00 (freq=2), username=diana (freq=2)
    DECLARE
        age_25_found boolean := false;
        salary_80000_found boolean := false;
        username_diana_found boolean := false;
    BEGIN
        FOR v IN SELECT * FROM jsonb_to_recordset(vals) AS (
            "columnName" text, "value" text, "frequency" int, "percent" numeric
        ) LOOP
            IF v."columnName" = 'age' AND v."value" = '25' THEN
                ASSERT v."frequency" = 3, 'age 25 frequency mismatch';
                ASSERT v."percent" = 0.6000, 'age 25 percent mismatch';
                age_25_found := true;
            ELSIF v."columnName" = 'salary' AND v."value" = '80000.00' THEN
                ASSERT v."frequency" = 2, 'salary 80000 frequency mismatch';
                ASSERT v."percent" = 0.4000, 'salary 80000 percent mismatch';
                salary_80000_found := true;
            ELSIF v."columnName" = 'username' AND v."value" = 'diana' THEN
                ASSERT v."frequency" = 2, 'username diana frequency mismatch';
                ASSERT v."percent" = 0.4000, 'username diana percent mismatch';
                username_diana_found := true;
            END IF;
        END LOOP;

        ASSERT age_25_found, 'age 25 value distribution missing';
        ASSERT salary_80000_found, 'salary 80000 value distribution missing';
        ASSERT username_diana_found, 'username diana value distribution missing';
    END;

    -- Test limiting options
    res := supa_profile.profile_table('mock_users'::regclass, '{"rows_per_table": 3}'::jsonb);
    ASSERT (res -> 'tableStats' ->> 'rowCount')::int = 3, 'rows_per_table limit option failed';
    ASSERT res ->> 'queryMode' = 'FAST', 'FAST queryMode mismatch for sampled table';

    -- Test disabling numeric stats
    res := supa_profile.profile_table('mock_users'::regclass, '{"calculate_numeric_stats": false}'::jsonb);
    FOR f IN SELECT * FROM jsonb_to_recordset(res -> 'fields') AS ("columnName" text, "avgValue" numeric, "median" numeric) LOOP
        IF f."columnName" = 'age' THEN
            ASSERT f."avgValue" IS NULL, 'avgValue should be null when numeric stats are disabled';
            ASSERT f."median" IS NULL, 'median should be null when numeric stats are disabled';
        END IF;
    END LOOP;

    -- Test disabling value distribution scan
    res := supa_profile.profile_table('mock_users'::regclass, '{"scan_field_values": false}'::jsonb);
    ASSERT jsonb_array_length(res -> 'values') = 0, 'values array should be empty when scan_field_values is false';

    RAISE NOTICE '✅ All supa_profile unit tests passed successfully!';
END;
$$;

DROP TABLE IF EXISTS mock_users;
DROP SCHEMA supa_profile CASCADE;

ROLLBACK;
