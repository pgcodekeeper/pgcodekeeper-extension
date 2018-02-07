SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION keep_drop_command() RETURNS event_trigger
    LANGUAGE plpgsql
    SET search_path = @extschema@, pg_catalog
    AS $$
    DECLARE
        r record;
    BEGIN
        FOR r IN SELECT * FROM pg_event_trigger_dropped_objects() LOOP 
            IF NOT r.is_temporary 
            THEN
                DELETE FROM ddl_events 
                WHERE classid = r.classid 
                    AND objid = r.objid;
            END IF; 
        END LOOP;
    END;
$$;