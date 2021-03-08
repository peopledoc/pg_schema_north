BEGIN;
  SET ROLE dba;

SET search_path TO public; -- We DONT WANT the objects to go anywhere else.
CREATE TABLE IF NOT EXISTS sql_version (
 	id serial PRIMARY KEY,
 	version_num text UNIQUE NOT NULL,
 	deployment_period tstzrange NOT NULL DEFAULT tstzrange(now(), NULL, '[)')
);

CREATE TABLE IF NOT EXISTS sql_ddl_statements (
  id serial primary key,
  run_ts timestamp with time zone NOT NULL default statement_timestamp(),
  command_tags text[],
  current_query text NOT NULL,
  version_num text REFERENCES sql_version(version_num),
  search_path text not null
);

ALTER TABLE sql_version ALTER deployment_period SET DEFAULT tstzrange(now(), NULL, '[)');

-- Update the primary key if we have the old version
DO LANGUAGE plpgsql
$doblock$
DECLARE
  current_pk text;
BEGIN
SELECT string_agg(attname, ',') INTO current_pk
FROM (
  SELECT conrelid, attnum FROM pg_constraint,
  LATERAL unnest(conkey) as attnums(attnum)
  WHERE contype = 'p' AND conrelid = 'sql_ddl_statements'::regclass
) as attnums
JOIN pg_attribute ON pg_attribute.attnum = attnums.attnum AND pg_attribute.attrelid = attnums.conrelid;
IF current_pk = 'run_ts,current_query' THEN
  ALTER TABLE sql_ddl_statements ADD column id serial;
  ALTER TABLE sql_ddl_statements DROP CONSTRAINT sql_ddl_statements_pkey;
  ALTER TABLE sql_ddl_statements ADD PRIMARY KEY (id);
END IF;
END;
$doblock$;


CREATE INDEX IF NOT EXISTS sql_ddl_statements__version_num ON sql_ddl_statements(version_num);

DO LANGUAGE plpgsql
$function$
BEGIN
        PERFORM 1 FROM pg_constraint
        WHERE conname='period_overlap'
          AND conrelid='sql_version'::regclass;
        IF NOT FOUND THEN
                ALTER TABLE sql_version
                ADD CONSTRAINT period_overlap EXCLUDE
                USING gist (deployment_period WITH &&);
       END IF;
END;
$function$;


DO LANGUAGE plpgsql
$function$
BEGIN
        PERFORM 1 FROM pg_constraint
        WHERE conname='version_is_numeric'
          AND conrelid='sql_version'::regclass;
        IF NOT FOUND THEN
                ALTER TABLE sql_version
                ADD CONSTRAINT version_is_numeric CHECK
                (version_num ~ '^\d+(\.\d+)*$');
       END IF;
END;
$function$;

-- Add column on installations not having it
DO LANGUAGE plpgsql
$function$
BEGIN
        PERFORM 1 FROM pg_attribute WHERE attrelid = 'sql_version'::regclass AND attname = 'run_by';
        IF NOT FOUND THEN
                ALTER TABLE sql_version ADD run_by name;
        END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION sql_ddl_statements_log() RETURNS event_trigger SECURITY DEFINER AS
$$
BEGIN
  PERFORM 1 FROM public.sql_ddl_statements WHERE current_query = current_query() AND run_ts = statement_timestamp();
  IF NOT FOUND THEN
    INSERT INTO public.sql_ddl_statements (command_tags, current_query, version_num, search_path)
      SELECT ARRAY[tg_tag], current_query(), (SELECT version_num FROM public.sql_version WHERE upper_inf(deployment_period)),
             current_setting('search_path');
  END IF;
END
$$ language plpgsql;


SET ROLE postgres;
DO $$
  BEGIN
  -- We don't need them on biologic.
  IF current_database() = 'biologic' THEN
    DROP EVENT TRIGGER IF EXISTS sql_ddl_statements_log;
    RETURN;
  END IF;
  PERFORM 1 FROM pg_event_trigger WHERE evtname = 'sql_ddl_statements_log' AND 'COMMENT' = ANY(evttags) AND 'ALTER VIEW' = ANY(evttags);
  IF NOT FOUND THEN
    DROP EVENT TRIGGER IF EXISTS sql_ddl_statements_log;
    CREATE EVENT TRIGGER sql_ddl_statements_log ON ddl_command_end
     WHEN TAG IN (
        'ALTER FUNCTION',
        'ALTER TABLE',
        'ALTER TYPE',
        'COMMENT',
        'CREATE FUNCTION',
        'CREATE SCHEMA',
        'CREATE SEQUENCE',
        'CREATE TABLE',
        'CREATE TABLE AS',
        'CREATE TYPE',
        'CREATE VIEW',
        'ALTER VIEW',
        'DROP FUNCTION',
        'DROP TABLE',
        'DROP VIEW')
    EXECUTE PROCEDURE public.sql_ddl_statements_log();
  END IF;
  END
$$ language plpgsql;

CREATE OR REPLACE FUNCTION dba_create_event_trigger(mode character varying)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
BEGIN
    CASE mode
        WHEN 'create' THEN
            EXECUTE 'CREATE EVENT TRIGGER check_regenerate_functions_on_command_end
              ON ddl_command_end
              EXECUTE PROCEDURE regenerate_functions_on_command_end()';
        WHEN 'drop' THEN
            EXECUTE 'DROP EVENT TRIGGER check_regenerate_functions_on_command_end';
        ELSE
            RAISE EXCEPTION 'This function must be called with create or drop parameter';
    END CASE;
END;
$function$;

GRANT EXECUTE ON FUNCTION dba_create_event_trigger(varchar) TO dba;

SET ROLE dba;


CREATE OR REPLACE FUNCTION check_has_event_trigger_function() RETURNS boolean
    LANGUAGE plpgsql
    AS $function$
DECLARE
        has_create_trigger_function boolean :=false;
BEGIN
        SELECT count(*)=1 INTO has_create_trigger_function
        FROM pg_proc
        WHERE proname='dba_create_event_trigger'
          AND prosecdef
          AND exists (SELECT 1 FROM pg_proc WHERE proname = 'pg_event_trigger_ddl_commands');
        RETURN has_create_trigger_function;
END
$function$;

-- Used because in 9.4 we don't have current_setting(text,boolean)
-- When we have nothing older than 9.6, this can go
CREATE OR REPLACE FUNCTION current_setting_nofail(psetting text)
  RETURNS TEXT
  LANGUAGE plpgsql
AS $function$
DECLARE
        v_setting text;
BEGIN
        SELECT into v_setting current_setting(psetting);
        RETURN v_setting;
EXCEPTION WHEN others THEN
        RETURN NULL;
END;
$function$;

DROP FUNCTION IF EXISTS begin_deploy_version(text);

-- The current like in "the version we are working on"
CREATE OR REPLACE FUNCTION current_sql_version()
  RETURNS TEXT
  LANGUAGE sql
AS $function$
  SELECT version_num
  FROM sql_version
  ORDER BY regexp_split_to_array(version_num,'\.')::int[] DESC
  LIMIT 1;
$function$;

-- This one returns the last completed version, which may be
-- the previous one from current_sql_version
CREATE OR REPLACE FUNCTION last_deployed_sql_version()
  RETURNS TEXT
  LANGUAGE sql
AS $function$
  SELECT version_num
  FROM sql_version
  WHERE upper(deployment_period) is not null
  ORDER BY regexp_split_to_array(version_num,'\.')::int[] DESC
  LIMIT 1;
$function$;




CREATE OR REPLACE FUNCTION begin_deploy_version(current_version_num text, new_version_num text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_current_version text;
  v_last_unfinished_version text;
  v_lax_versioning text; -- should be boolean, but as it is a user guc, it will be text
BEGIN
        IF current_version_num = new_version_num THEN
            RAISE 'You''re trying to upgrade from % to %, they are the same',
              current_version_num,new_version_num;
        END IF;

        -- Are we trying to install a new version, when the previous one hasn't been finished ?
        SELECT INTO v_last_unfinished_version version_num
        FROM sql_version
        WHERE upper(deployment_period)='infinity';
        IF FOUND THEN
            RAISE 'The version % is already in progress',
              v_last_unfinished_version;
        END IF;

        -- Are we trying to downgrade ?
        IF regexp_split_to_array(new_version_num,'\.')::int[] < regexp_split_to_array(current_version_num,'\.')::int[] THEN
            RAISE 'You''re trying to downgrade to %, from %',
              new_version_num,current_version_num;
        END IF;

        -- Get the current version in the database
        v_current_version := coalesce(public.current_sql_version(), regexp_replace(obj_description('public.sql_version'::regclass), 'version ', ''));

        -- Special case: if current_version_num returns NULL, it means sql_version is empty
        -- This can only occur in two cases:
        -- We lost sql_version's content, which shouldn't happen except if the database is corrupted
        -- We are starting from an empty database, which means we are in CI
        -- So perform next block's tests only if v_current_version isn't null

        IF v_current_version IS NOT NULL THEN
                -- Check we are starting from latest version
                -- We may have null if we start from scratch on a new sql_version table
                IF v_current_version IS DISTINCT FROM current_version_num THEN
                    RAISE 'The actual version is %, you''re trying to upgrade from %',
                      v_current_version, current_version_num;
                END IF;

                -- Are we trying to install a version that has already been installed
                -- This shouldn't happen, of course, as it means we are downgrading
                -- It would mean there are weird inconsistencies in the sql_version table,
                -- better catch them anyway
                PERFORM 1 FROM sql_version WHERE version_num=new_version_num;
                IF FOUND THEN
                    RAISE 'You''re trying to update to %, which has already been installed',
                      new_version_num;
                END IF;
        ELSE
                RAISE WARNING 'This database''s sql_version is empty. Stop NOW if you aren''t in CI!';
        END IF;

        -- We are OK with this version. Let's go

        INSERT INTO sql_version(version_num, run_by) VALUES (new_version_num, session_user);

        IF check_has_event_trigger_function() THEN
            PERFORM dba_create_event_trigger('create');
        ELSE
            RAISE WARNING 'Cannot create migration event triggers. This is serious if you are on a staging or production environment';
        END IF;

EXCEPTION WHEN raise_exception OR integrity_constraint_violation THEN
        -- There is no pg_setting(text,boolean) in 9.4. So I need to use the pg_settings view...
        SELECT INTO v_lax_versioning current_setting_nofail('dev.lax_versioning');
        IF v_lax_versioning IS NULL OR v_lax_versioning !~* '^(on|true|1|yes)$' THEN
                -- The setting is not here... the exception goes up
                RAISE;
        ELSE
                RAISE NOTICE 'You are using dev.lax_versioning. Ignoring inconsistencies in upgrade path';
        END IF;
END;
$function$;


CREATE OR REPLACE FUNCTION end_deploy_version(new_version_num text) RETURNS void
    LANGUAGE plpgsql
    AS $function$
DECLARE
        row_id integer;
        v_lax_versioning text; -- should be boolean, but as it is a user guc, it will be text
BEGIN
        UPDATE sql_version SET deployment_period = tstzrange(lower(deployment_period), now(), '[)')
                WHERE version_num = new_version_num
                RETURNING id INTO row_id;
        IF row_id IS NULL THEN
                RAISE EXCEPTION 'Cannot close a non-opened migration';
        END IF;

        IF check_has_event_trigger_function() THEN
            PERFORM dba_create_event_trigger('drop');
        END IF;

EXCEPTION WHEN raise_exception OR integrity_constraint_violation THEN
        -- There is no pg_setting(text,boolean) in 9.4. So I need to use the pg_settings view...
        SELECT INTO v_lax_versioning current_setting_nofail('dev.lax_versioning');
        IF v_lax_versioning IS NULL OR v_lax_versioning !~* '^(on|true|1|yes)$' THEN
                -- The setting is not here... the exception goes up
                RAISE;
        ELSE
                RAISE NOTICE 'You are using dev.lax_versioning. Ignoring inconsistencies in upgrade path';
        END IF;
END;
$function$;

-- Find all type oids (and class) depending on a type
-- Returns both as it makes it possible to find what depends on a type and all its subtypes:
-- tables (just have to check what the pg_class record is)
-- types (any derived type, even a table type derived from a type used in another table)
-- functions... just pick the objtype you are interested in, and if it is a pg_class, check the rest of the metadata in pg_class
create or replace function recurse_type (IN p_oid oid, IN p_objtype oid, p_depth int default 0, seen_oids oid[] default '{}')
  RETURNS TABLE (objid oid, objtype oid)
  language plpgsql
AS
$$
DECLARE
  v_oid oid;
  v_classid oid;
  v_result oid[]; -- this will be a bi-dimensional array storing all results
  v_temp oid[]; -- temp value for loop on v_temp_results
  v_upper int;
BEGIN
    RAISE debug 'Called for oid:%, type:%, depth:%, seen_oids:%',p_oid,p_objtype,p_depth, seen_oids;
    IF seen_oids @> ARRAY[p_oid] THEN
        RAISE debug 'oid already seen: %',p_oid;
        RETURN;
    END IF;
    RAISE debug '% not found',p_oid;
    -- Return the current object
    objid:=p_oid; objtype:=p_objtype;
    RETURN NEXT;
    seen_oids:=seen_oids||p_oid;
    -- Find all dependant objects, and call this function recursively for each one
    -- distinct because a single dependency can be here several type because of different deptypes
    FOR v_oid,v_classid IN SELECT DISTINCT d.objid,d.classid FROM pg_catalog.pg_depend d
                WHERE refobjid=p_oid
                  AND refclassid=p_objtype
    LOOP

        -- We're going to temporarily store all found records in an array...

        -- recurse whatever the type
        RAISE DEBUG 'Recursing for %,%',v_oid,v_classid;

        SELECT array_agg(ARRAY[r.objid,r.objtype]) INTO v_temp FROM recurse_type(v_oid,v_classid,p_depth+1,seen_oids) r;
        v_result:=v_result||v_temp;
        RAISE DEBUG 'v_temp:%',v_temp;
    END LOOP;
    RAISE DEBUG 'v_result:%',v_result;


    -- Add missing elements to seen_oids. Get the first column (still is a 2d array, and flatten it)
    -- This is an ugly fix for 9.4. We can get rid of it when migrated to 9.6+ (the code becomes
    -- seen_oids:=seen_oids||ARRAY(SELECT unnest(v_result[1:][1]));
    v_upper:=array_upper(v_result,1);
    seen_oids:=seen_oids||ARRAY(SELECT unnest(v_result[1:v_upper][1]));

    -- Some dependencies cannot be found there: a type defined as a composite
    -- doesn't have entries on pg_depend, only on pg_attribute, so let's go there too
    -- we fetch array types from arrays to at the same time, as both are simple

    -- Find all attributes linked to our class, to find composites
    IF p_objtype::regclass='pg_catalog.pg_class'::regclass THEN
        RAISE debug 'Searching for attributes of %',p_oid;
        SELECT array_agg(ARRAY[(r).objid,(r).objtype]) INTO v_temp
              FROM (SELECT recurse_type(a.attrelid,'pg_catalog.pg_class'::regclass::oid,p_depth+1,seen_oids) r
                    FROM pg_catalog.pg_attribute a
                    WHERE a.atttypid=p_oid) as tmp;
        v_result:=v_result||v_temp;
    END IF;

    -- Add missing elements to seen_oids. Get the first column (still is a 2d array, and flatten it)
    -- This is an ugly fix for 9.4. We can get rid of it when migrated to 9.6+ (the code becomes
    -- seen_oids:=seen_oids||ARRAY(SELECT unnest(v_result[1:][1]));
    v_upper:=array_upper(v_result,1);
    seen_oids:=seen_oids||ARRAY(SELECT unnest(v_result[1:v_upper][1]));

    -- Find if there wouldn't by chance be a type associated with the relation we found ?
    -- this may be nasty: typrelid isn't indexed, and pg_attribute may be big
    IF p_objtype::regclass='pg_catalog.pg_class'::regclass THEN
        RAISE debug 'Going back to a type from pg_class of %',p_oid;
        SELECT array_agg(ARRAY[(r).objid,(r).objtype]) INTO v_temp
              FROM (SELECT recurse_type(t.oid,'pg_catalog.pg_type'::regclass::oid,p_depth+1,seen_oids) r
                    FROM pg_catalog.pg_type t
                    WHERE t.typrelid=p_oid ) as tmp;
        v_result:=v_result||v_temp;
    END IF;

    -- Add missing elements to seen_oids. Get the first column (still is a 2d array, and flatten it)
    -- This is an ugly fix for 9.4. We can get rid of it when migrated to 9.6+ (the code becomes
    -- seen_oids:=seen_oids||ARRAY(SELECT unnest(v_result[1:][1]));
    v_upper:=array_upper(v_result,1);
    seen_oids:=seen_oids||ARRAY(SELECT unnest(v_result[1:v_upper][1]));

    -- Find the array types associated with this type (array as in [], these are real types too)
    -- this may be nasty: typrelid isn't indexed, and pg_attribute may be big
    IF p_objtype::regclass='pg_catalog.pg_type'::regclass THEN
        RAISE debug 'Searching for arrays of %',p_oid;
        SELECT array_agg(ARRAY[(r).objid,(r).objtype]) INTO v_temp
              FROM ( SELECT recurse_type(t.typarray,'pg_catalog.pg_type'::regclass::oid,p_depth+1,seen_oids) r
                     FROM pg_catalog.pg_type t
                     WHERE t.oid=p_oid AND t.typarray IS DISTINCT FROM 0) as tmp;
        v_result:=v_result||v_temp;
   END IF;

    -- Add missing elements to seen_oids. Get the first column (still is a 2d array, and flatten it)
    -- This is an ugly fix for 9.4. We can get rid of it when migrated to 9.6+ (the code becomes
    -- seen_oids:=seen_oids||ARRAY(SELECT unnest(v_result[1:][1]));
    v_upper:=array_upper(v_result,1);
    seen_oids:=seen_oids||ARRAY(SELECT unnest(v_result[1:v_upper][1]));

   -- We might also be a pg_rewrite object. Then continue with this view
   IF p_objtype::regclass='pg_catalog.pg_rewrite'::regclass THEN
        RAISE debug 'Adding the view relative to our pg_rewrite %',p_oid;
        SELECT array_agg(ARRAY[(r).objid,(r).objtype]) INTO v_temp
                     FROM (SELECT recurse_type(rw.ev_class,'pg_catalog.pg_class'::regclass::oid,p_depth+1,seen_oids) r
                            FROM pg_catalog.pg_rewrite rw
                            WHERE rw.oid=p_oid) as tmp;
        v_result:=v_result||v_temp;
    END IF;

    -- Add missing elements to seen_oids. Get the first column (still is a 2d array, and flatten it)
    -- This is an ugly fix for 9.4. We can get rid of it when migrated to 9.6+ (the code becomes
    -- seen_oids:=seen_oids||ARRAY(SELECT unnest(v_result[1:][1]));
    v_upper:=array_upper(v_result,1);
    seen_oids:=seen_oids||ARRAY(SELECT unnest(v_result[1:v_upper][1]));

    IF v_result IS NOT NULL THEN
        FOREACH v_temp SLICE 1 IN ARRAY v_result
        LOOP

            -- If we dont know this element, return it
            objid:=v_temp[1]; objtype:=v_temp[2];
            RETURN NEXT;
        END LOOP;
    END IF;

END;
$$
;

SET ROLE postgres;
CREATE OR REPLACE FUNCTION regenerate_functions_on_command_end()
 RETURNS event_trigger
 LANGUAGE plpgsql AS
$$
DECLARE
    affected_object record;
    shorter_name text;
    rewrite_function record;
    dependant_objects text[];
BEGIN
    FOR affected_object IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        IF affected_object.object_type = 'table' THEN
            -- Quick hack, as we don't use schemas in the PL functions usually
            shorter_name := substring(affected_object.object_identity FROM (position('.' in affected_object.object_identity) + 1));
            -- Get dependant_objects names; regexp characters shouldn't be in type names
            -- So from now on, |, [, ], \ aren't allowed in type names (and let's keep it that way)
            select array_agg (objname) INTO dependant_objects
            FROM (
                    SELECT DISTINCT CASE WHEN objid::regtype::text<>objid::text THEN objid::regtype::text
                                         WHEN objid::regclass::text<>objid::text THEN objid::regclass::text
                                         ELSE NULL END AS objname
                    FROM recurse_type(affected_object.objid,'pg_class'::regclass)
                  ) AS tmp
            WHERE objname NOT LIKE '%[]'; -- arrays will be matched anyway, and [] won't work in the regexp
            -- Find all affected objects
            FOR rewrite_function IN
                SELECT oid,pg_get_functiondef(oid) as def FROM pg_proc WHERE prosrc LIKE '%' || shorter_name || '%'
                                                                         AND prolang IN (SELECT oid FROM pg_language WHERE lanname ='plpgsql' )
                                                                         AND pronamespace IN (SELECT oid FROM pg_namespace WHERE nspname NOT IN ('pg_catalog','pg_toast','information_schema'))
                UNION
                SELECT oid,pg_get_functiondef(oid) as def FROM pg_proc WHERE prosrc ~ array_to_string(dependant_objects,'|')
                                                                         AND prolang IN (SELECT oid FROM pg_language WHERE lanname ='plpgsql' )
                                                                         AND pronamespace IN (SELECT oid FROM pg_namespace WHERE nspname NOT IN ('pg_catalog','pg_toast','information_schema'))
            LOOP
                RAISE WARNING 'rewrote function % to protect from execution errors',rewrite_function.oid::regproc::text;
                EXECUTE rewrite_function.def;
            END LOOP;
        END IF;
    END LOOP;
END;
$$;
-- We need to make sure the previous function postgres/security definer
ALTER FUNCTION regenerate_functions_on_command_end() OWNER TO postgres;
ALTER FUNCTION regenerate_functions_on_command_end() SECURITY DEFINER;

CREATE OR REPLACE FUNCTION update_leakproofness() RETURNS VOID AS $$
  UPDATE pg_proc
    SET proleakproof = true
  FROM pg_language
  WHERE pg_language.oid = pg_proc.prolang
  /* Can be leakproof:
      - every "internal" function
      - every function in pg_catalog
      - every function installed by an extension
  */
  AND NOT proleakproof
  AND (pg_proc.pronamespace = 'pg_catalog'::regnamespace
       OR pg_language.lanname = 'internal'
       OR EXISTS (
          SELECT 1 FROM pg_depend
          WHERE objid = pg_proc.oid
          AND refclassid = 'pg_extension'::regclass
          AND classid = 'pg_proc'::regclass
        ));
$$ language sql;

SELECT update_leakproofness();

-- Just in case someone adds something below this point...
SET ROLE dba;

COMMIT;
