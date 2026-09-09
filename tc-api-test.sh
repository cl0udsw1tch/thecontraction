#!/bin/bash
POSTGRES_DB="tc_test"

docker compose run --rm -e POSTGRES_DB=${POSTGRES_DB} tc-api npm run test
