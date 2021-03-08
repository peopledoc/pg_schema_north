DO
$$
DECLARE
    orphan_func_query text;
    orphan_func text;
    query_clause text;
    pg_version int;
BEGIN

    pg_version := pg_version_num();

    IF pg_version > 110000 THEN
        query_clause := 'prokind = ''f''';
    ELSE
        query_clause := 'NOT proiswindow AND NOT proisagg';
    END IF;

    FOR orphan_func IN
        EXECUTE 'SELECT a.proname orphan_func,c.nspname as schema
        FROM pg_proc a
        JOIN pg_type b ON a.prorettype = b.oid
        JOIN pg_namespace c ON a.pronamespace = c.oid
        WHERE ' || query_clause || '
            AND b.typname = ''trigger''
            AND c.nspname != ''pg_catalog''
            AND NOT EXISTS (
                SELECT 1
                FROM pg_trigger
                WHERE tgfoid = a.oid)
        ORDER BY 1'
    LOOP
        RAISE WARNING 'Orphan trigger functions: %',orphan_func;
    END LOOP;
END;
$$ LANGUAGE plpgsql;
