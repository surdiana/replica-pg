#!/bin/bash
set -e

# Define default values if environment variables are not set
ARCHIVE_PATH=${ARCHIVE_PATH:-./archive}
DATA_PATH=${DATA_PATH:-./replica_data}
POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-postgres}
POSTGRES_DB=${POSTGRES_DB:-postgres}  # Added custom database name parameter
REPLICATION_USER=${REPLICATION_USER:-replica}
REPLICATION_PASSWORD=${REPLICATION_PASSWORD:-replica}
POSTGRES_VERSION=${POSTGRES_VERSION:-15}
CONTAINER_NAME=${CONTAINER_NAME:-postgres_replica}
REPLICA_PORT=${REPLICA_PORT:-5433}

# Master server settings - HARUS DIISI
MASTER_HOST=${MASTER_HOST:-192.168.2.77}
MASTER_PORT=${MASTER_PORT:-5432}

# Get server's public IP
SERVER_IP=$(hostname -I | awk '{print $1}')

# Validasi parameter wajib
if [ -z "$MASTER_HOST" ]; then
  echo "ERROR: MASTER_HOST belum diatur. Jalankan script dengan: MASTER_HOST=x.x.x.x ./script.sh"
  exit 1
fi

echo "====== Initialize PostgreSQL Replica for Cross-Server Replication ======"
echo "Using the following configuration:"
echo "Container Name: $CONTAINER_NAME"
echo "PostgreSQL Version: $POSTGRES_VERSION"
echo "Database Name: $POSTGRES_DB"  # Added display of database name
echo "Master Host: $MASTER_HOST"
echo "Master Port: $MASTER_PORT"
echo "Archive Path: $ARCHIVE_PATH"
echo "Data Path: $DATA_PATH"
echo "PostgreSQL User: $POSTGRES_USER"
echo "Replication User: $REPLICATION_USER"
echo "Server IP: $SERVER_IP"
echo "Using network_mode: host for direct server-to-server communication"

# Create required directories if they don't exist
mkdir -p $ARCHIVE_PATH
mkdir -p configs
mkdir -p $DATA_PATH

# Check if the master is reachable
echo "Testing connectivity to master PostgreSQL server..."
if ! nc -z -w5 $MASTER_HOST $MASTER_PORT 2>/dev/null; then
  echo "✗ Cannot connect to PostgreSQL master at $MASTER_HOST:$MASTER_PORT"
  echo "Please verify that:"
  echo "  1. The master server is running"
  echo "  2. The master server is accessible from this host"
  echo "  3. Firewalls are properly configured"
  echo "  4. Network settings are correct"
  echo ""
  echo "Continuing anyway, but expect issues with pg_basebackup..."
else
  echo "✓ PostgreSQL master is reachable at $MASTER_HOST:$MASTER_PORT"
fi

# Test database connectivity to verify custom database exists
echo "Testing database connectivity to verify custom database exists..."
if command -v psql >/dev/null 2>&1; then
  if PGPASSWORD=$POSTGRES_PASSWORD psql -h $MASTER_HOST -p $MASTER_PORT -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT 1" >/dev/null 2>&1; then
    echo "✓ Successfully connected to database '$POSTGRES_DB' on master"
  else
    echo "✗ Could not connect to database '$POSTGRES_DB' on master"
    echo "Please verify that the database exists and is accessible"
    echo "You may need to create it first on the master with:"
    echo "POSTGRES_DB=$POSTGRES_DB ./master_setup.sh"
    echo ""
    echo "Continuing anyway, but expect issues..."
  fi
else
  echo "! psql client not found locally, skipping database connectivity test"
  echo "Installing postgresql-client package is recommended for troubleshooting"
fi

# Create pg_hba.conf for replica
echo "Creating pg_hba.conf for PostgreSQL access control..."
cat > configs/pg_hba.conf << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
# Local connections
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust

# Specific entries for custom database
local   $POSTGRES_DB    $POSTGRES_USER                          trust
host    $POSTGRES_DB    $POSTGRES_USER  127.0.0.1/32            trust
host    $POSTGRES_DB    $POSTGRES_USER  ::1/128                 trust

# Allow connections from master server
host    all             all             $MASTER_HOST/32         md5
host    $POSTGRES_DB    $POSTGRES_USER  $MASTER_HOST/32         md5
host    replication     $REPLICATION_USER $MASTER_HOST/32       md5

# Allow all local network connections
host    all             all             192.168.0.0/16          md5
host    $POSTGRES_DB    $POSTGRES_USER  192.168.0.0/16          md5
host    all             all             10.0.0.0/8              md5
host    $POSTGRES_DB    $POSTGRES_USER  10.0.0.0/8              md5
host    all             all             172.16.0.0/12           md5
host    $POSTGRES_DB    $POSTGRES_USER  172.16.0.0/12           md5
EOF

# Check if container already exists
if docker ps -a | grep -q "$CONTAINER_NAME"; then
  CONTAINER_EXISTS=true
  echo "Container $CONTAINER_NAME already exists."
  
  # Check if container is running
  if docker ps | grep -q "$CONTAINER_NAME"; then
    CONTAINER_RUNNING=true
    echo "Container is currently running. Stopping it to apply new settings..."
    docker stop $CONTAINER_NAME
    sleep 2
  else
    CONTAINER_RUNNING=false
    echo "Container exists but is not running."
  fi
  
  # Remove the container to allow recreation with new settings
  echo "Removing existing container to apply new settings..."
  docker rm $CONTAINER_NAME
  
  CONTAINER_EXISTS=false
else
  CONTAINER_EXISTS=false
  echo "Container does not exist. Creating new container..."
fi

# Create a recovery.conf for the replica
echo "Creating recovery configuration..."
cat > configs/recovery.conf << EOF
primary_conninfo = 'host=$MASTER_HOST port=$MASTER_PORT user=$REPLICATION_USER password=$REPLICATION_PASSWORD application_name=$CONTAINER_NAME'
primary_slot_name = 'replica_slot'
EOF

# Create temporary container to perform pg_basebackup
echo "Creating temporary container for pg_basebackup..."
docker run --rm \
  --network=host \
  -v ${DATA_PATH}:/var/lib/postgresql/data \
  postgres:$POSTGRES_VERSION \
  bash -c "rm -rf /var/lib/postgresql/data/* && chown postgres:postgres /var/lib/postgresql/data"

# Perform pg_basebackup
echo "Performing pg_basebackup from master server..."
docker run --rm \
  --network=host \
  -v ${DATA_PATH}:/var/lib/postgresql/data \
  -v $(pwd)/configs:/configs \
  postgres:$POSTGRES_VERSION \
  bash -c "
    set -e
    echo 'Executing pg_basebackup...'
    PGPASSWORD=$REPLICATION_PASSWORD pg_basebackup -h $MASTER_HOST -p $MASTER_PORT -U $REPLICATION_USER \
      -D /var/lib/postgresql/data -Fp -Xs -P -v \
      && echo 'pg_basebackup completed successfully' \
      || { echo 'pg_basebackup failed'; exit 1; }
    
    echo 'Creating standby.signal...'
    touch /var/lib/postgresql/data/standby.signal
    
    echo 'Setting permissions...'
    chmod 700 /var/lib/postgresql/data
    
    echo 'Creating postgresql.auto.conf entries...'
    cat > /var/lib/postgresql/data/postgresql.auto.conf << INNEREOF
# Auto-generated postgresql.auto.conf for replica
primary_conninfo = 'host=$MASTER_HOST port=$MASTER_PORT user=$REPLICATION_USER password=$REPLICATION_PASSWORD application_name=$CONTAINER_NAME'
primary_slot_name = 'replica_slot'
hot_standby = on
INNEREOF
    
    echo 'Copying pg_hba.conf...'
    cp /configs/pg_hba.conf /var/lib/postgresql/data/pg_hba.conf
    
    echo 'Setup complete!'
  "

# Create docker-compose.yml with host network mode
echo "Creating docker-compose.yml with host network mode..."
cat > docker-compose.yml << EOF
version: '3.8'

services:
  $CONTAINER_NAME:
    image: postgres:$POSTGRES_VERSION
    container_name: $CONTAINER_NAME
    environment:
      POSTGRES_USER: $POSTGRES_USER
      POSTGRES_PASSWORD: $POSTGRES_PASSWORD
      POSTGRES_DB: $POSTGRES_DB  # Added custom database name
    network_mode: "host"
    volumes:
      - ${DATA_PATH}:/var/lib/postgresql/data
      - ${ARCHIVE_PATH}:/var/lib/postgresql/archive
    restart: always
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
      interval: 5s
      timeout: 5s
      retries: 5

EOF

# Start PostgreSQL using docker-compose
echo "Starting PostgreSQL replica..."
docker-compose up -d

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL replica to be ready..."
max_attempts=30
attempt=0

while [ $attempt -lt $max_attempts ]; do
  # Check if PostgreSQL is accepting connections to postgres database first
  if docker exec $CONTAINER_NAME pg_isready -U $POSTGRES_USER 2>/dev/null; then
    echo "PostgreSQL replica base system is up!"
    break
  fi
  
  attempt=$((attempt+1))
  echo "PostgreSQL replica is starting up (attempt $attempt of $max_attempts)... waiting"
  sleep 2
done

# Now ensure the custom database exists before trying to connect to it
echo "Ensuring custom database $POSTGRES_DB is accessible..."
attempt=0
max_attempts=10

while [ $attempt -lt $max_attempts ]; do
  # Check if we can list databases and see our database
  if docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -c "\l" 2>/dev/null | grep -q "$POSTGRES_DB"; then
    echo "✓ Database $POSTGRES_DB is visible in database list"
    
    # Try to connect to the database
    if docker exec $CONTAINER_NAME pg_isready -U $POSTGRES_USER -d $POSTGRES_DB 2>/dev/null; then
      echo "✓ Database $POSTGRES_DB is accessible"
      break
    fi
  fi
  
  attempt=$((attempt+1))
  echo "Waiting for database $POSTGRES_DB to be available (attempt $attempt of $max_attempts)..."
  sleep 3
done

if [ $attempt -eq $max_attempts ]; then
  echo "Warning: Custom database $POSTGRES_DB may not be properly replicated yet."
  echo "This is normal during initial setup and should resolve within a few minutes."
  echo "Continuing with verification steps..."
fi

# Verify replica is in recovery mode
echo "Verifying replica is in recovery mode..."
attempt=0
max_attempts=5
RECOVERY_STATUS="error"

while [ $attempt -lt $max_attempts ]; do
  RECOVERY_STATUS=$(docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")
  if [ "$RECOVERY_STATUS" == "t" ]; then
    echo "✓ Replica is in recovery mode (streaming replication is active)"
    break
  else
    attempt=$((attempt+1))
    echo "Checking recovery status (attempt $attempt of $max_attempts)... waiting"
    sleep 2
  fi
done

if [ "$RECOVERY_STATUS" != "t" ]; then
  echo "✗ Replica is not in recovery mode. Streaming replication may not be working."
  echo "Please check logs with: docker logs $CONTAINER_NAME"
fi

# Display connection info
echo "Displaying replication status from replica:"
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -c "SELECT * FROM pg_stat_wal_receiver;"

# Check for replication lag
echo "Checking for replication lag..."
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -c "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"

# Verify specifically that custom database exists and is being replicated
echo "Verifying custom database replication..."
attempt=0
max_attempts=5

while [ $attempt -lt $max_attempts ]; do
  if docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -c "\l" 2>/dev/null | grep -q "$POSTGRES_DB"; then
    echo "✓ Database '$POSTGRES_DB' is visible on replica"
    break
  else
    attempt=$((attempt+1))
    echo "Waiting for database '$POSTGRES_DB' to appear on replica (attempt $attempt of $max_attempts)..."
    sleep 3
  fi
done

if [ $attempt -eq $max_attempts ]; then
  echo "✗ Database '$POSTGRES_DB' not found on replica after $max_attempts attempts"
  echo "This indicates a potential replication issue. Please check logs."
fi

# Check for test table created on master
echo "Checking for test table created on master..."
attempt=0
max_attempts=10

while [ $attempt -lt $max_attempts ]; do
  # First check if we can connect to the database
  if docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT 1" >/dev/null 2>&1; then
    # Now check for the test table
    if docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "\dt replication_test" 2>/dev/null | grep -q 'replication_test'; then
      echo "✓ Test table 'replication_test' found in $POSTGRES_DB database"
      echo "Showing test data:"
      docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT * FROM replication_test;"
      break
    fi
  fi
  
  attempt=$((attempt+1))
  echo "Waiting for test table to be replicated (attempt $attempt of $max_attempts)..."
  sleep 3
done

if [ $attempt -eq $max_attempts ]; then
  echo "✗ Test table 'replication_test' not found in $POSTGRES_DB database after $max_attempts attempts"
  echo "This could indicate replication issues or that the table wasn't created on master"
fi

echo "====== PostgreSQL Replica Setup Complete ======"
echo ""
echo "To connect to replica: psql -h $SERVER_IP -p $REPLICA_PORT -U $POSTGRES_USER -d $POSTGRES_DB"
echo ""
echo "If replication is not working, try the following:"
echo "1. Check master server logs: docker logs postgres_master"
echo "2. Check replica logs: docker logs $CONTAINER_NAME"
echo "3. Verify network connectivity between servers"
echo "4. Ensure master's pg_hba.conf allows connections from $SERVER_IP"
echo "5. Check if the replication slot is active: psql -h $MASTER_HOST -U $POSTGRES_USER -c \"SELECT * FROM pg_replication_slots;\""
echo "6. Verify the database exists on master: psql -h $MASTER_HOST -U $POSTGRES_USER -c \"\\l\" | grep \"$POSTGRES_DB\""