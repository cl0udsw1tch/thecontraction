#!/bin/bash
set -e
docker compose up -d;
sleep 1;
docker compose exec -d tc-api npm run migrate;
