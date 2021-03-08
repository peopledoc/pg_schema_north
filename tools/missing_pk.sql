DO
$$
DECLARE
    pkquery varchar;
    missing_pks text;
BEGIN

    pkquery := 'select string_agg(pg_class.oid::regclass::text,'', '')
    from pg_class
    join pg_namespace
    on (pg_class.relnamespace=pg_namespace.oid)
    where relkind=''r''
      and pg_class.oid not in (select conrelid from pg_constraint where contype=''p'')
      and nspname not in (
           ''pg_catalog'',
           ''information_schema'',
           ''_timescaledb_catalog'',
           ''_timescaledb_internal'',
           ''_timescaledb_cache'')';

    EXECUTE pkquery INTO missing_pks;
    IF length(missing_pks) > 0 THEN
        RAISE 'Missing PK on: %',missing_pks;
    END IF;
END;
$$ LANGUAGE plpgsql;

