#!/bin/bash
set -a
source .env
set +a

(cd tc-api && npx prisma studio --url postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:${POSTGRES_PORT}/${POSTGRES_DB} )
