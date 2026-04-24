# ----- Kiln ATS — migration runner -----
# Tiny image that only contains the `goose` CLI + psql client.
# Migrations are NOT copied in — they're bind-mounted at run time from
# backend/db/migrations so the image doesn't need a rebuild every time
# a new migration is added.
#
# Built and invoked by migration.sh.
# ----------------------------------------

FROM alpine:3.20

ARG GOOSE_VERSION=v3.25.0

RUN apk add --no-cache ca-certificates wget bash postgresql-client \
 && wget -qO /usr/local/bin/goose \
      "https://github.com/pressly/goose/releases/download/${GOOSE_VERSION}/goose_linux_x86_64" \
 && chmod +x /usr/local/bin/goose \
 && goose -version

WORKDIR /app

# env/.env.<env> provides GOOSE_DRIVER and GOOSE_DBSTRING;
# migration.sh overrides GOOSE_MIGRATION_DIR to point at the bind-mount.
ENV GOOSE_DRIVER=postgres
ENV GOOSE_MIGRATION_DIR=/app/migrations

ENTRYPOINT ["goose"]
