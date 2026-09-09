#!/bin/bash
docker compose up -d;
docker compose exec tc-api npm run migrate;
