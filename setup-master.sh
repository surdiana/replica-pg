#!/bin/bash
set -e

# Define default values if environment variables are not set
ARCHIVE_PATH=${ARCHIVE_PATH:-./archive}
DATA_PATH=${DATA_PATH:-./pg_data}
POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-postgres}
POSTGRES_DB=${POSTGRES_DB:-postgres}  # Custom database name parameter
REPLICATION_USER=${REPLICATION_USER:-replica}
REPLICATION_PASSWORD=${REPLICATION_PASSWORD:-replica}
POSTGRES_VERSION=${POSTGRES_VERSION:-15}
CONTAINER_NAME=${CONTAINER_NAME:-postgres_master}

# Define IP bindings array with format: "ip:port"
# Default: localhost:5432
if [ -z "$IP_BINDINGS" ]; then
  IP_BINDINGS=("192.168.2.77:5432")
fi

# Define pg_hba allowed IPs
# By default, include localhost and Docker networks
if [ -z "$PG_HBA_ALLOWED_IPS" ]; then
  PG_HBA_ALLOWED_IPS=(
    "192.168.2.77/32"
  )
fi

echo "====== Initialize PostgreSQL Replication ======"
echo "Using the following configuration:"
echo "Container Name: $CONTAINER_NAME"
echo "PostgreSQL Version: $POSTGRES_VERSION"
echo "Database Name: $POSTGRES_DB"  # Display custom database name
echo "Archive Path: $ARCHIVE_PATH"
echo "Data Path: $DATA_PATH"
echo "PostgreSQL User: $POSTGRES_USER"
echo "Replication User: $REPLICATION_USER"
echo "IP Bindings:"
for binding in "${IP_BINDINGS[@]}"; do
  echo "  - $binding"
done
echo "Allowed pg_hba networks:"
for network in "${PG_HBA_ALLOWED_IPS[@]}"; do
  echo "  - $network"
done

# Function to check if an IP is valid and available on this host
is_valid_ip() {
  local ip=$1
  
  # Special case for localhost and all interfaces
  if [ "$ip" == "127.0.0.1" ] || [ "$ip" == "0.0.0.0" ]; then
    return 0
  fi
  
  # Try using ifconfig if available
  if command -v ifconfig >/dev/null 2>&1; then
    if ifconfig | grep -q "$ip"; then
      return 0
    fi
  fi
  
  # Try using ip addr if available
  if command -v ip >/dev/null 2>&1; then
    if ip addr | grep -q "$ip"; then
      return 0
    fi
  fi
  
  # If we still couldn't validate, assume it's not valid
  return 1
}

# Validate IP bindings
VALID_IP_BINDINGS=()
echo "Validating IP bindings..."
for binding in "${IP_BINDINGS[@]}"; do
  ip=$(echo $binding | cut -d ':' -f1)
  port=$(echo $binding | cut -d ':' -f2)
  
  if is_valid_ip "$ip"; then
    VALID_IP_BINDINGS+=("$binding")
    echo "  ✓ $binding is valid"
  else
    echo "  ✗ $ip is not assigned to any network interface."
    echo "    Converting to 0.0.0.0:$port (all interfaces)"
    VALID_IP_BINDINGS+=("0.0.0.0:$port")
  fi
done

# If no valid IPs, fall back to localhost
if [ ${#VALID_IP_BINDINGS[@]} -eq 0 ]; then
  echo "No valid IP bindings found. Falling back to 0.0.0.0:5432 (all interfaces)"
  VALID_IP_BINDINGS=("0.0.0.0:5432")
fi

# Replace the original array with the validated one
IP_BINDINGS=("${VALID_IP_BINDINGS[@]}")

# Create required directories if they don't exist
mkdir -p $ARCHIVE_PATH
mkdir -p configs

# Create pg_hba.conf with common default entries
echo "Creating pg_hba.conf for PostgreSQL access control..."
cat > configs/pg_hba.conf << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
# Local connections
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust

# Custom database specific entries
local   $POSTGRES_DB    $POSTGRES_USER                          trust
host    $POSTGRES_DB    $POSTGRES_USER  127.0.0.1/32            trust
host    $POSTGRES_DB    $POSTGRES_USER  ::1/128                 trust

# Replication connections - local
host    replication     all             127.0.0.1/32            trust
host    replication     all             ::1/128                 trust

# User-defined pg_hba entries
EOF

# Add entries for each allowed IP in PG_HBA_ALLOWED_IPS
for network in "${PG_HBA_ALLOWED_IPS[@]}"; do
  # Skip localhost as it's already added above
  if [ "$network" != "127.0.0.1/32" ] && [ "$network" != "::1/128" ]; then
    echo "host    all             $POSTGRES_USER      $network               md5" >> configs/pg_hba.conf
    echo "host    $POSTGRES_DB    $POSTGRES_USER      $network               md5" >> configs/pg_hba.conf
    echo "host    replication     $REPLICATION_USER   $network               md5" >> configs/pg_hba.conf
  fi
done

# Also add any wildcard IPs from IP_BINDINGS that should allow connections
for binding in "${IP_BINDINGS[@]}"; do
  # Split the binding into IP and port
  ip=$(echo $binding | cut -d ':' -f1)
  
  # If it's a wildcard IP (0.0.0.0), add entry for all IPs
  if [ "$ip" == "0.0.0.0" ] && ! echo "${PG_HBA_ALLOWED_IPS[@]}" | grep -q "0.0.0.0/0"; then
    echo "# Adding wildcard entry from IP_BINDINGS" >> configs/pg_hba.conf
    echo "host    all             $POSTGRES_USER      0.0.0.0/0               md5" >> configs/pg_hba.conf
    echo "host    $POSTGRES_DB    $POSTGRES_USER      0.0.0.0/0               md5" >> configs/pg_hba.conf
    echo "host    replication     $REPLICATION_USER   0.0.0.0/0               md5" >> configs/pg_hba.conf
  fi
done

# Create a separate Docker network bindings configuration
echo "Creating Docker IP bindings configuration..."
cat > configs/docker_network_bindings.conf << EOF
# Docker network bindings for container: $CONTAINER_NAME
# Generated on: $(date)
#
# IP:PORT bindings for Docker container:
EOF

# Add entries for each IP in the bindings
for binding in "${IP_BINDINGS[@]}"; do
  # Split the binding into IP and port
  ip=$(echo $binding | cut -d ':' -f1)
  port=$(echo $binding | cut -d ':' -f2)
  
  # Add to Docker bindings file
  echo "$ip:$port -> container 5432" >> configs/docker_network_bindings.conf
done

# Display the created pg_hba.conf
echo "Created pg_hba.conf with the following content:"
cat configs/pg_hba.conf

echo "Created Docker network bindings configuration:"
cat configs/docker_network_bindings.conf

# Create postgresql.conf customizations
echo "Creating postgresql.conf customizations..."
cat > configs/custom_postgresql.conf << EOF
# Custom PostgreSQL configuration for replication
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
archive_mode = on
archive_command = 'test -f %p && cp %p ${ARCHIVE_PATH}/%f || exit 0'
EOF

# Check if container already exists
if docker ps -a | grep -q "$CONTAINER_NAME"; then
  CONTAINER_EXISTS=true
  echo "Container $CONTAINER_NAME already exists."
  
  # Check if container is running
  if docker ps | grep -q "$CONTAINER_NAME"; then
    CONTAINER_RUNNING=true
    echo "Container is currently running. Stopping it to apply new network settings..."
    docker stop $CONTAINER_NAME
    sleep 2
  else
    CONTAINER_RUNNING=false
    echo "Container exists but is not running."
  fi
  
  # Remove the container to allow recreation with new network settings
  echo "Removing existing container to apply new network settings..."
  docker rm $CONTAINER_NAME
  
  CONTAINER_EXISTS=false
else
  CONTAINER_EXISTS=false
  echo "Container does not exist. Creating new container..."
fi

# Create docker-compose.yml with dynamic port bindings
echo "Creating docker-compose.yml with IP bindings..."
cat > docker-compose.yml << EOF
version: '3.8'

services:
  $CONTAINER_NAME:
    image: postgres:$POSTGRES_VERSION
    container_name: $CONTAINER_NAME
    environment:
      POSTGRES_USER: $POSTGRES_USER
      POSTGRES_PASSWORD: $POSTGRES_PASSWORD
      POSTGRES_DB: $POSTGRES_DB  # Custom database name
    ports:
EOF

# Add all IP bindings from the array
for binding in "${IP_BINDINGS[@]}"; do
  # Split the binding into IP and port
  ip=$(echo $binding | cut -d ':' -f1)
  port=$(echo $binding | cut -d ':' -f2)
  echo "      - \"$binding:5432\"" >> docker-compose.yml
done

# Continue with the rest of the docker-compose file
cat >> docker-compose.yml << EOF
    volumes:
      - ./configs/pg_hba.conf:/tmp/pg_hba.conf
      - ${ARCHIVE_PATH}:/var/lib/postgresql/archive
      - ${DATA_PATH}:/var/lib/postgresql/data
    command: >
      postgres
        -c "listen_addresses=*"
        -c "wal_level=replica"
        -c "max_wal_senders=10"
        -c "max_replication_slots=10"
        -c "hot_standby=on"
        -c "archive_mode=on"
        -c "archive_command='test -f %p && cp %p /var/lib/postgresql/archive/%f || exit 0'"
        -c "hba_file=/tmp/pg_hba.conf"
    networks:
      - postgres_network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
      interval: 5s
      timeout: 5s
      retries: 5

networks:
  postgres_network:
    driver: bridge
EOF

# Start PostgreSQL using docker-compose
echo "Starting PostgreSQL master..."
docker-compose up -d

# Wait for PostgreSQL to be ready - MORE ROBUST CHECK
echo "Waiting for PostgreSQL master to be ready..."
max_attempts=30
attempt=0

while [ $attempt -lt $max_attempts ]; do
  # Check if PostgreSQL is accepting connections, specifically for our custom database
  if docker exec $CONTAINER_NAME pg_isready -U $POSTGRES_USER -d $POSTGRES_DB; then
    # Additional check: verify PostgreSQL is fully started by attempting a simple query on the custom database
    if docker exec -i $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT 1" >/dev/null 2>&1; then
      echo "PostgreSQL is up and ready with database $POSTGRES_DB!"
      break
    fi
  fi
  
  attempt=$((attempt+1))
  echo "PostgreSQL is starting up (attempt $attempt of $max_attempts)... waiting"
  sleep 2
done

if [ $attempt -eq $max_attempts ]; then
  echo "Error: PostgreSQL failed to start properly after $max_attempts attempts."
  exit 1
fi

# Wait a bit more to ensure PostgreSQL is fully operational
echo "Giving PostgreSQL a few more seconds to fully initialize..."
sleep 10

# Create database if it doesn't exist
echo "Ensuring database $POSTGRES_DB exists..."
attempt=0
max_attempts=5

while [ $attempt -lt $max_attempts ]; do
  if docker exec -i $CONTAINER_NAME psql -U $POSTGRES_USER -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$POSTGRES_DB'" | grep -q 1; then
    echo "✓ Database $POSTGRES_DB exists."
    break
  else
    echo "Creating database $POSTGRES_DB..."
    if docker exec -i $CONTAINER_NAME psql -U $POSTGRES_USER -d postgres -c "CREATE DATABASE $POSTGRES_DB;" >/dev/null 2>&1; then
      echo "✓ Successfully created database $POSTGRES_DB."
      break
    fi
  fi
  
  attempt=$((attempt+1))
  if [ $attempt -lt $max_attempts ]; then
    echo "Failed to ensure database exists (attempt $attempt of $max_attempts). Retrying in 3 seconds..."
    sleep 3
  fi
done

if [ $attempt -eq $max_attempts ]; then
  echo "Warning: Failed to ensure database exists after $max_attempts attempts."
  echo "PostgreSQL container logs:"
  docker logs $CONTAINER_NAME --tail 20
  echo "Trying a different approach to create the database..."
  docker exec -i $CONTAINER_NAME bash -c "createdb -U $POSTGRES_USER $POSTGRES_DB" || echo "Failed to create database using createdb"
fi

if [ $attempt -eq $max_attempts ]; then
  echo "Warning: Failed to ensure database exists after $max_attempts attempts."
  # Show PostgreSQL logs to help diagnose
  echo "PostgreSQL container logs:"
  docker logs $CONTAINER_NAME --tail 20
  exit 1
fi

# Create replication user with more robust error handling
echo "Creating replication user..."
attempt=0
max_attempts=5

docker exec -i $CONTAINER_NAME psql -U $POSTGRES_USER -d postgres -c "DROP ROLE IF EXISTS $REPLICATION_USER;" >/dev/null 2>&1 || true
echo "Removed existing replication user if it existed."

while [ $attempt -lt $max_attempts ]; do
  if docker exec -i $CONTAINER_NAME psql -U $POSTGRES_USER -d postgres -c "CREATE ROLE $REPLICATION_USER WITH REPLICATION PASSWORD '$REPLICATION_PASSWORD' LOGIN;" >/dev/null 2>&1; then
    echo "✓ Replication user created successfully!"
    break
  else
    # Check if the user already exists but might have different permissions
    if docker exec -i $CONTAINER_NAME psql -U $POSTGRES_USER -d postgres -c "SELECT 1 FROM pg_roles WHERE rolname='$REPLICATION_USER'" | grep -q 1; then
      echo "User exists but may need different permissions. Altering role..."
      docker exec -i $CONTAINER_NAME psql -U $POSTGRES_USER -d postgres -c "ALTER ROLE $REPLICATION_USER WITH REPLICATION PASSWORD '$REPLICATION_PASSWORD' LOGIN;" >/dev/null 2>&1
      echo "✓ Replication user updated successfully!"
      break
    fi
  fi
  
  attempt=$((attempt+1))
  if [ $attempt -lt $max_attempts ]; then
    echo "Failed to create replication user (attempt $attempt of $max_attempts). Retrying in 3 seconds..."
    sleep 3
  fi
done
    echo "Replication user created successfully!"
    break
  else
    attempt=$((attempt+1))
    echo "Failed to create replication user (attempt $attempt of $max_attempts). Retrying in 2 seconds..."
    sleep 2
  fi
done

if [ $attempt -eq $max_attempts ]; then
  echo "Warning: Failed to create replication user after $max_attempts attempts."
  # Show PostgreSQL logs to help diagnose
  echo "PostgreSQL container logs:"
  docker logs $CONTAINER_NAME --tail 10
  
  echo "Checking if user already exists:"
  docker exec -i $CONTAINER_NAME psql -U $POSTGRES_USER -d postgres -c "SELECT rolname, rolreplication FROM pg_roles WHERE rolname='$REPLICATION_USER';" || true
fi

# Create replication slot with error handling
echo "Creating replication slot..."
attempt=0
max_attempts=5

# First, drop the slot if it exists
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d postgres -c "SELECT pg_drop_replication_slot('replica_slot') FROM pg_replication_slots WHERE slot_name='replica_slot';" >/dev/null 2>&1 || true
echo "Removed existing replication slot if it existed."

while [ $attempt -lt $max_attempts ]; do
  if docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d postgres -c "SELECT pg_create_physical_replication_slot('replica_slot');" >/dev/null 2>&1; then
    echo "Replication slot created successfully!"
    break
  else
    # Check if slot already exists
    if docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d postgres -c "SELECT 1 FROM pg_replication_slots WHERE slot_name='replica_slot';" | grep -q 1; then
      echo "✓ Replication slot already exists."
      break
    fi
  fi
  
  attempt=$((attempt+1))
  if [ $attempt -lt $max_attempts ]; then
    echo "Failed to create replication slot (attempt $attempt of $max_attempts). Retrying in 3 seconds..."
    sleep 3
  fi
done

if [ $attempt -eq $max_attempts ]; then
  echo "Warning: Failed to create replication slot after $max_attempts attempts."
  echo "Checking current replication slots:"
  docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d postgres -c "SELECT * FROM pg_replication_slots;" || true
fi

# Verify configuration - using custom database where appropriate
echo "Verifying master configuration..."
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "SHOW wal_level;"
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "SHOW max_wal_senders;"
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "SHOW max_replication_slots;"
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT * FROM pg_replication_slots;"
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT * FROM pg_roles WHERE rolname='$REPLICATION_USER';"
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT pg_read_file(current_setting('hba_file'), 0, 1000);"

# Create a test table in the custom database to verify write access
echo "Creating a test table in $POSTGRES_DB database to verify write access..."
attempt=0
max_attempts=5

while [ $attempt -lt $max_attempts ]; do
  if docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
  CREATE TABLE IF NOT EXISTS replication_test (
      id SERIAL PRIMARY KEY,
      test_name VARCHAR(100) NOT NULL,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );" >/dev/null 2>&1; then
    echo "✓ Successfully created test table in $POSTGRES_DB."
    break
  else
    attempt=$((attempt+1))
    echo "Failed to create test table (attempt $attempt of $max_attempts). Retrying in 2 seconds..."
    sleep 2
  fi
done

if [ $attempt -eq $max_attempts ]; then
  echo "Warning: Failed to create test table after $max_attempts attempts."
fi

docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
INSERT INTO replication_test (test_name) VALUES ('Initial replication test') RETURNING id;"

# Display information about the custom database
echo "Verifying custom database setup..."
# Check if database exists, if not create it
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -c "SELECT 1 FROM pg_database WHERE datname = '$POSTGRES_DB'" | grep -q 1 || docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -c "CREATE DATABASE $POSTGRES_DB;"
# Now verify the database exists
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -c "\l" | grep "$POSTGRES_DB"
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "\dt"

# Display container IP
echo "IP address PostgreSQL master: $(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $CONTAINER_NAME)"

# Display docker port mappings to verify bindings
echo "Docker port mappings:"
docker port $CONTAINER_NAME

# Additional verification steps for custom database
echo "Testing connection to custom database with replication user..."
docker exec $CONTAINER_NAME psql -U $REPLICATION_USER -d $POSTGRES_DB -c "SELECT current_database();" || echo "Note: Replication user might not have direct database access permissions"

# Verify WAL (Write-Ahead Log) is properly configured for replication with the custom database
echo "Verifying WAL configuration for replication..."
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
SELECT 
    name,
    setting,
    boot_val,
    reset_val,
    unit
FROM pg_settings 
WHERE name IN ('wal_level', 'max_wal_senders', 'max_replication_slots', 'hot_standby', 'archive_mode');"

echo "====== PostgreSQL Replication Setup Complete ======"
echo "Custom database '$POSTGRES_DB' is successfully configured."
echo "To connect to this database use the following parameters:"
echo "  Host: <your-server-ip>"
for binding in "${IP_BINDINGS[@]}"; do
  port=$(echo $binding | cut -d ':' -f2)
  echo "  Port: $port"
done
echo "  Database: $POSTGRES_DB"
echo "  User: $POSTGRES_USER"