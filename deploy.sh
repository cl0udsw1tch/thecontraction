#!/bin/bash
set -e
docker compose up -d;
sleep 1;
docker compose exec tc-api npm run migrate;
