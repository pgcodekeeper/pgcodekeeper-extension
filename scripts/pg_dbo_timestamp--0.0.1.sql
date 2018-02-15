\echo Use "CREATE EXTENSION pg_dbo_timestamp" to load this file. \quit
SET search_path = @extschema@, pg_catalog;

CREATE OR REPLACE FUNCTION initial_time_keeper() RETURNS void
    LANGUAGE plpgsql
    SET search_path = @extschema@, pg_catalog
    AS $$
	DECLARE
		pg_cat_schema  oid;
		inf_schema	   oid;
		extension_deps oid[];
	BEGIN
		SELECT n.oid INTO pg_cat_schema FROM pg_namespace n WHERE n.nspname = 'pg_catalog';
		SELECT n.oid INTO inf_schema FROM pg_namespace n WHERE n.nspname = 'information_schema';

		extension_deps := array( SELECT dep.objid FROM pg_catalog.pg_depend dep WHERE refclassid = 'pg_extension'::regclass AND dep.deptype = 'e');

		--clear table, because have unique primary key
		DELETE FROM ddl_events;

		--all schemas
		INSERT INTO ddl_events (classid, objid, author) SELECT 'pg_namespace'::regclass::oid, n.oid, null
		FROM pg_namespace n 
		WHERE n.nspname NOT LIKE 'pg\_%' 
			AND n.nspname != 'information_schema'
			AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend dp WHERE dp.objid = n.oid AND dp.deptype = 'e');

		--all extensions
		INSERT INTO ddl_events (classid, objid, author) SELECT 'pg_extension'::regclass::oid, e.oid, null
		FROM pg_extension e;

		-- all types
		INSERT INTO ddl_events (classid, objid, author) SELECT 'pg_type'::regclass::oid, t.oid, null
		FROM pg_type t 
		WHERE t.typisdefined = TRUE 
		    AND (t.typrelid = 0 OR (SELECT c.relkind FROM pg_catalog.pg_class c WHERE c.oid = t.typrelid) = 'c')
		    AND NOT EXISTS(SELECT 1 FROM pg_catalog.pg_type el WHERE el.oid = t.typelem AND el.typarray = t.oid)
		    AND t.typnamespace != pg_cat_schema 
		    AND t.typnamespace != inf_schema
		    AND NOT t.oid = ANY (extension_deps);

		--all functions
		INSERT INTO ddl_events (classid, objid, author) SELECT 'pg_proc'::regclass::oid, p.oid, null
		FROM pg_proc p 
		WHERE p.pronamespace != pg_cat_schema 
			AND p.pronamespace != inf_schema
			AND NOT p.oid = ANY (extension_deps);

		--all relations
		INSERT INTO ddl_events (classid, objid, author) SELECT 'pg_class'::regclass::oid, c.oid, null
		FROM pg_class c
		WHERE c.relkind IN ('f','r','p','v','m','S')
			AND c.relnamespace != pg_cat_schema 
			AND c.relnamespace != inf_schema
			AND NOT c.oid = ANY (extension_deps);

		--all indices
		INSERT INTO ddl_events (classid, objid, author) SELECT 'pg_class'::regclass::oid, c.oid, null
		FROM pg_catalog.pg_index ind
		JOIN pg_catalog.pg_class c ON c.oid = ind.indexrelid
		LEFT JOIN pg_catalog.pg_constraint cons ON cons.conindid = ind.indexrelid
			AND cons.contype IN ('p', 'u', 'x')
		WHERE c.relkind = 'i'
			AND c.relnamespace != pg_cat_schema 
			AND c.relnamespace != inf_schema
			AND NOT c.oid = ANY (extension_deps)
			AND ind.indisprimary = FALSE
			AND ind.indisexclusion = FALSE
			AND cons.conindid is NULL;	

		--all triggers
		INSERT INTO ddl_events (classid, objid, author) SELECT 'pg_trigger'::regclass::oid, t.oid, null
		FROM pg_catalog.pg_class c
		RIGHT JOIN pg_catalog.pg_trigger t ON c.oid = t.tgrelid
		WHERE c.relkind IN ('r', 'f', 'p', 'm', 'v')
			AND t.tgisinternal = FALSE			
			AND c.relnamespace != pg_cat_schema 
			AND c.relnamespace != inf_schema
			AND NOT t.oid = ANY (extension_deps);

		--all rules
		INSERT INTO ddl_events (classid, objid, author) SELECT 'pg_rewrite'::regclass::oid, r.oid, null
		FROM pg_catalog.pg_rewrite r
		JOIN pg_catalog.pg_class c ON c.oid = r.ev_class 
		WHERE 	c.relnamespace != pg_cat_schema 
			AND c.relnamespace != inf_schema
			AND NOT r.oid = ANY (extension_deps)
			AND NOT (c.relkind IN ('v', 'm') AND r.ev_type = '1' AND r.is_instead);
		
	END;
	$$;

CREATE OR REPLACE FUNCTION keep_any_command() RETURNS event_trigger
    LANGUAGE plpgsql
    SET search_path = @extschema@, pg_catalog
    AS $$
    DECLARE
        r record;
    BEGIN
        FOR r IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
            IF r.classid IS NOT NUll AND r.objid IS NOT NULL 
            THEN
                IF EXISTS (
                SELECT 1 from ddl_events WHERE classid = r.classid AND objid = r.objid)
                THEN 
                    UPDATE ddl_events SET last_modified = DEFAULT, author = DEFAULT 
                    WHERE classid = r.classid AND objid = r.objid;
                ELSE
                    INSERT INTO ddl_events (classid, objid) SELECT r.classid, r.objid;
                END IF;
            ELSE 
                RAISE WARNING 'Unsupported operation';
            END IF;
        END LOOP;
    END;
$$;

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

CREATE TABLE ddl_events (
	classid oid NOT NULL,
	objid oid NOT NULL,
	last_modified timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
	author name DEFAULT CURRENT_USER
);

ALTER TABLE ddl_events
	ADD CONSTRAINT events_pkey PRIMARY KEY (classid, objid);

CREATE VIEW show_objects AS
	SELECT 
            t.objid,
            f.type,
            f.schema,
            f.name,
            f.identity,
            t.last_modified,
            t.author
   FROM ddl_events t,
            LATERAL pg_identify_object(t.classid, t.objid, 0) f(type, schema, name, identity);

CREATE EVENT TRIGGER keep_drop_ddl_timestamps ON sql_drop
   EXECUTE PROCEDURE keep_drop_command();

CREATE EVENT TRIGGER keep_ddl_timestamps ON ddl_command_end
   EXECUTE PROCEDURE keep_any_command();

SELECT initial_time_keeper();

ALTER EVENT TRIGGER keep_ddl_timestamps DISABLE;