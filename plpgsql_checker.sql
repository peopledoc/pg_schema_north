-- Check every function in the db with plpgsql_check
CREATE EXTENSION plpgsql_check;

-- put all search paths that could be found
SET search_path TO casemgmt,process,public;

SELECT
    CASE WHEN tgname IS NOT NULL THEN 'TRIGGER ' || tgname || ' ON ' || tgtable ELSE '' END AS context,
    (pcf).functionid::regprocedure,
    (pcf).lineno, (pcf).statement,
    (pcf).sqlstate, (pcf).message, (pcf).detail, (pcf).hint, (pcf).level,
    (pcf)."position", (pcf).query, (pcf).context
FROM
(
    SELECT
        plpgsql_check_function_tb(funcoid:= pg_proc.oid,
                                  relid:= COALESCE(pg_trigger.tgrelid, 0),
                                  oldtable:=pg_trigger.tgoldtable,
                                  newtable:=pg_trigger.tgnewtable
                                 ) AS pcf,
        pg_trigger.tgrelid::regclass::text as tgtable,
        pg_trigger.tgname
    FROM pg_proc
    LEFT JOIN pg_trigger
        ON (pg_trigger.tgfoid = pg_proc.oid)
    WHERE
        -- ignore things from extensions since we can't fix them
        NOT EXISTS (SELECT 1 FROM pg_depend WHERE objid = pg_proc.oid AND refclassid = 'pg_extension'::regclass) AND
        prolang = (SELECT lang.oid FROM pg_language lang WHERE lang.lanname = 'plpgsql') AND
        pronamespace <> (SELECT nsp.oid FROM pg_namespace nsp WHERE nsp.nspname = 'pg_catalog') AND
        -- ignore unused triggers
        (pg_proc.prorettype <> (SELECT typ.oid FROM pg_type typ WHERE typ.typname = 'trigger' AND typ.typnamespace = 'pg_catalog'::regnamespace) OR
         pg_trigger.tgfoid IS NOT NULL)

    OFFSET 0
) ss
WHERE (pcf).functionid::regprocedure::text !~ '^dba_|deploy_version\('
   AND (pcf).message !~ '^OUT variable .* is maybe unmodified$'
-- dba functions call different system functions depending on PG's version. begin/end deploy depend on functions that may not be there (in qualif)
and (pcf).functionid::regprocedure::text !~ '^dba_|^begin_deploy_version|^end_deploy_version'
ORDER BY (pcf).functionid::regprocedure::text, (pcf).lineno;
