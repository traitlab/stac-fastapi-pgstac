# Fix: pgstac database data lost on every redeploy

## Problem

Every time the STAC VM (in `tf-rpp-elalib`) gets redeployed, the pgstac
Postgres database is empty afterward, requiring a full re-ingestion of STAC
index files into the API via `stac-fastapi-pgstac`'s `app` container.

## Root cause

This is **not** caused by the VM/Terraform side losing its disks. On the
infrastructure side, `modules/stac/main.tf` in `tf-rpp-elalib` attaches two
OpenStack block volumes (`vol-docker`, `vol-app`) that are created once as
persistent resources in the `environments/persistent` Terraform state and
never destroyed when the VM itself is destroyed/recreated. `mount_volumes.sh`
only runs `mkfs.ext4` on a volume if it has no existing filesystem, so the
volumes' contents genuinely survive a VM redeploy.

The actual cause is in **this repo's `docker-compose.yml`**:

```yaml
  database:
    image: ghcr.io/stac-utils/pgstac:v0.9.8
    environment:
      - POSTGRES_USER=username
      - POSTGRES_PASSWORD=password
      - POSTGRES_DB=postgis
      - PGUSER=username
      - PGPASSWORD=password
      - PGDATABASE=postgis
    ports:
      - "5439:5432"
    command: postgres -N 500
```

There is **no `volumes:` entry** mapping Postgres's data directory
(`/var/lib/postgresql/data`) anywhere persistent. Postgres writes all its
data into the `database` container's own ephemeral writable layer.

Combine that with `tf-rpp-elalib`'s deploy script
(`modules/stac/cloud-config-setup-stac-fastapi-pgstac.tft` →
`setup-stac-fastapi-pgstac.sh`), which runs on every deploy:

```bash
docker stop stac-fastapi-pgstac-database-1 stac-fastapi-pgstac-app-1 | true
docker rm stac-fastapi-pgstac-database-1 stac-fastapi-pgstac-app-1 | true
docker rmi ghcr.io/stac-utils/pgstac:v0.9.8 | true
docker rmi stac-utils/stac-fastapi-pgstac:latest | true
rm -rf "${CLONE_PARENT}/${PROJECT_DIR}" | true
git clone ...   # fresh clone
```

`docker rm` on a container with no named/bound volume destroys its data
immediately - there's nothing to `rm -v` even; the data was never anywhere
else to begin with. This would lose data on **any** container recreation,
not just a full VM redeploy - e.g. just running `run.sh` again, or a plain
`docker compose down && docker compose up`, would already reproduce this.

## Fix

Give the `database` service a named volume for its data directory, and
declare it at the top level so Docker Compose creates/reuses it independently
of the container's own lifecycle:

```yaml
services:
  database:
    image: ghcr.io/stac-utils/pgstac:v0.9.8
    environment:
      - POSTGRES_USER=username
      - POSTGRES_PASSWORD=password
      - POSTGRES_DB=postgis
      - PGUSER=username
      - PGPASSWORD=password
      - PGDATABASE=postgis
    ports:
      - "5439:5432"
    command: postgres -N 500
    volumes:
      - pgstac-data:/var/lib/postgresql/data   # <-- add this

  # ...other services unchanged...

volumes:
  pgstac-data:   # <-- add this top-level declaration
```

Named volumes are NOT removed by `docker rm <container>` (without `-v`), so
this specific script's existing `docker stop`/`docker rm`/`docker rmi`
sequence stays safe once this is in place - it removes the container and
image, not the volume, and the next `docker compose up -d database` will
reattach to the same volume and find its data intact.

On the infra side (`tf-rpp-elalib`), this also matters for disk space, not
just persistence: the STAC VM's root disk is a fixed 20GB (`/`), already
tight. Docker's `data-root` is relocated to `/mnt/docker` specifically to
keep container/volume data off that small root disk - confirmed in
`modules/stac/cloud-config.yaml`:

```
rsync -aP /var/lib/docker/ /mnt/docker
...
"data-root": "/mnt/docker"
```

So the named volume this fix adds lands under `/mnt/docker/volumes/...`
automatically (Docker always creates named volumes under its configured
`data-root`), which is itself one of the persistent OpenStack block volumes
mounted by `mount_volumes.sh` - it survives a full VM redeploy, not just a
container-level restart, and it's nowhere near the constrained root disk.

Checked for other volume-destroying commands in this repo (`docker compose
down -v`, `docker volume rm`, etc.) across `run.sh`, the `Makefile`, and
`scripts/` - none found, so this one change should be sufficient.

## Verifying the fix

1. Add the volume mapping above, commit, deploy once (this pass will still
   start from an empty database, same as today - the fix is forward-looking).
2. Ingest the STAC index files as usual.
3. Trigger `run.sh` again (or redeploy the VM) without changing this file.
4. Confirm the previously-ingested collections/items are still present via
   the API (`GET /collections`) instead of an empty catalog.
5. `docker volume ls` / `docker volume inspect <name>` to confirm the volume
   name Compose actually generated (typically
   `<project-dir-name>_pgstac-data`) and that it persists across step 3.

## Not in scope here

- Whether `POSTGRES_USER`/`POSTGRES_PASSWORD` should move out of
  plaintext `environment:` entries - separate concern, not addressed by
  this fix.
- The `app` service's own state is already stateless (reads from the
  database), so it needs no equivalent change.
