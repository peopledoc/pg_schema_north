-- This MUST be run as superuser (postgres for instance)
-- It is SECURITY DEFINER

BEGIN;
CREATE FUNCTION dba_create_event_trigger(mode varchar)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
AS
$$
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
$$;
REVOKE ALL ON FUNCTION dba_create_event_trigger(varchar) FROM PUBLIC; -- to be sure, but should already be ok
GRANT EXECUTE ON FUNCTION dba_create_event_trigger(varchar) TO dba;
COMMIT;

