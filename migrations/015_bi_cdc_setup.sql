--liquibase formatted sql

--changeset warehouse:015_bi_cdc_setup runInTransaction:true splitStatements:false rollbackSplitStatements:false
DO $$
DECLARE
  debezium_user text := '${debeziumUser}';
  debezium_password text := '${debeziumPassword}';
  publication_name text := '${debeziumPublicationName}';
  metabase_user text := '${metabaseDbUser}';
  metabase_password text := '${metabaseDbPassword}';
BEGIN
  IF debezium_user IS NULL OR debezium_user = '' THEN
    RAISE EXCEPTION 'debeziumUser must be provided';
  END IF;

  IF debezium_password IS NULL OR debezium_password = '' THEN
    RAISE EXCEPTION 'debeziumPassword must be provided';
  END IF;

  IF publication_name IS NULL OR publication_name = '' THEN
    RAISE EXCEPTION 'debeziumPublicationName must be provided';
  END IF;

  IF metabase_user IS NULL OR metabase_user = '' THEN
    RAISE EXCEPTION 'metabaseDbUser must be provided';
  END IF;

  IF metabase_password IS NULL OR metabase_password = '' THEN
    RAISE EXCEPTION 'metabaseDbPassword must be provided';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles
    WHERE rolname = debezium_user
  ) THEN
    EXECUTE format(
      'CREATE ROLE %I WITH LOGIN REPLICATION PASSWORD %L',
      debezium_user,
      debezium_password
    );
  ELSE
    EXECUTE format(
      'ALTER ROLE %I WITH LOGIN REPLICATION PASSWORD %L',
      debezium_user,
      debezium_password
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles
    WHERE rolname = metabase_user
  ) THEN
    EXECUTE format(
      'CREATE ROLE %I WITH LOGIN PASSWORD %L',
      metabase_user,
      metabase_password
    );
  ELSE
    EXECUTE format(
      'ALTER ROLE %I WITH LOGIN PASSWORD %L',
      metabase_user,
      metabase_password
    );
  END IF;

  EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), debezium_user);
  EXECUTE format('GRANT USAGE ON SCHEMA public TO %I', debezium_user);
  EXECUTE format('GRANT SELECT ON TABLE public.inventory_movements TO %I', debezium_user);

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_publication
    WHERE pubname = publication_name
  ) THEN
    EXECUTE format(
      'CREATE PUBLICATION %I FOR TABLE public.inventory_movements',
      publication_name
    );
  ELSE
    EXECUTE format(
      'ALTER PUBLICATION %I SET TABLE public.inventory_movements',
      publication_name
    );
  END IF;
END $$;

--rollback DO $$
--rollback DECLARE
--rollback   debezium_user text := '${debeziumUser}';
--rollback   publication_name text := '${debeziumPublicationName}';
--rollback BEGIN
--rollback   IF publication_name IS NOT NULL AND publication_name <> '' THEN
--rollback     EXECUTE format('DROP PUBLICATION IF EXISTS %I', publication_name);
--rollback   END IF;
--rollback   IF debezium_user IS NOT NULL AND debezium_user <> '' THEN
--rollback     EXECUTE format('REVOKE SELECT ON TABLE public.inventory_movements FROM %I', debezium_user);
--rollback     EXECUTE format('REVOKE USAGE ON SCHEMA public FROM %I', debezium_user);
--rollback     EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM %I', current_database(), debezium_user);
--rollback   END IF;
--rollback END $$;

--changeset warehouse:015_tag
--tagDatabase v015
--rollback empty
