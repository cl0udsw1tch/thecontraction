#!/bin/bash

set -a
source .env
set +a

POSTGRES_DB="tc_test"

docker compose run --rm \
    -e POSTGRES_DB=${POSTGRES_DB} \
    -e DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:${POSTGRES_PORT}/${POSTGRES_DB} \
    tc-api sh -c "npm run migrate && npm run test"
