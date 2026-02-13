#/bin/bash

set -ex

date

# Usage: run.sh <env> <branch> <tag>
# Example: run.sh vbox vlf-dev 6.2.1-vlf

if [ $# -ne 3 ]; then
  echo "Usage: $0 <env> <branch> <tag>"
  echo "Example: $0 vbox vlf-dev 6.2.1-vlf"
  exit 1
fi

ENV=$1
BRANCH=$2
TAG=$3

ENV_FILE=".env@${ENV}"
if [ ! -f "$ENV_FILE" ]; then
  echo "Error: $ENV_FILE not found"
  exit 1
fi

echo "=== Fetching and pulling $BRANCH ==="
git fetch --tags --force && git pull origin "$BRANCH"

echo "=== Checking out tag $TAG ==="
git checkout -f "$TAG"

echo "=== Copying $ENV_FILE to .env ==="
cp "$ENV_FILE" .env

echo "=== Building database and app ==="
sudo docker compose build database
sudo docker compose build app

echo "=== Creating containers ==="
sudo docker compose create database
sudo docker compose create app

echo "=== Starting services ==="
sudo docker compose up -d database
sleep 3
sudo docker compose up -d app

echo "=== Done ==="

echo

date
