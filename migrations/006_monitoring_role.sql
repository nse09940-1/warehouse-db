--liquibase formatted sql

--changeset warehouse:006_monitoring_role runInTransaction:true splitStatements:false rollbackSplitStatements:false
DO $$
DECLARE
  exporter_user text := '${postgresExporterUser}';
  exporter_password text := '${postgresExporterPassword}';
BEGIN
  IF exporter_user IS NULL OR exporter_user = '' THEN
    RAISE EXCEPTION 'postgresExporterUser must be provided';
  END IF;

  IF exporter_password IS NULL OR exporter_password = '' THEN
    RAISE EXCEPTION 'postgresExporterPassword must be provided';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles
    WHERE rolname = exporter_user
  ) THEN
    EXECUTE format(
      'CREATE ROLE %I WITH LOGIN PASSWORD %L',
      exporter_user,
      exporter_password
    );
  ELSE
    EXECUTE format(
      'ALTER ROLE %I WITH LOGIN PASSWORD %L',
      exporter_user,
      exporter_password
    );
  END IF;

  EXECUTE format('GRANT pg_monitor TO %I', exporter_user);
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), exporter_user);
END $$;

--rollback DO $$
--rollback DECLARE
--rollback   exporter_user text := '${postgresExporterUser}';
--rollback BEGIN
--rollback   EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM %I', current_database(), exporter_user);
--rollback END $$;

--changeset warehouse:006_tag
--tagDatabase v006
--rollback empty
