#!/bin/bash
set -e

# Define default values if environment variables are not set
ARCHIVE_PATH=${ARCHIVE_PATH:-./archive}
DATA_PATH=${DATA_PATH:-./pg_data}
POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-postgres}
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
archive_command = 'cp %p ${ARCHIVE_PATH}/%f'
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
        -c "archive_command='cp %p /var/lib/postgresql/archive/%f'"
        -c "hba_file=/tmp/pg_hba.conf"
    networks:
      - postgres_network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $POSTGRES_USER"]
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
  # Check if PostgreSQL is accepting connections
  if docker exec $CONTAINER_NAME pg_isready -U $POSTGRES_USER; then
    # Additional check: verify PostgreSQL is fully started by attempting a simple query
    if docker exec -i $CONTAINER_NAME psql -U $POSTGRES_USER -c "SELECT 1" >/dev/null 2>&1; then
      echo "PostgreSQL is up and ready!"
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
sleep 5

# Create replication user with more robust error handling
echo "Creating replication user..."
attempt=0
max_attempts=5

while [ $attempt -lt $max_attempts ]; do
  if docker exec -i $CONTAINER_NAME psql -U $POSTGRES_USER -c "CREATE ROLE $REPLICATION_USER WITH REPLICATION PASSWORD '$REPLICATION_PASSWORD' LOGIN;" >/dev/null 2>&1; then
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
  docker logs $CONTAINER_NAME --tail 20
fi

# Create replication slot with error handling
echo "Creating replication slot..."
attempt=0
max_attempts=5

while [ $attempt -lt $max_attempts ]; do
  if docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -c "SELECT pg_create_physical_replication_slot('replica_slot');" >/dev/null 2>&1; then
    echo "Replication slot created successfully!"
    break
  else
    attempt=$((attempt+1))
    echo "Failed to create replication slot (attempt $attempt of $max_attempts). Retrying in 2 seconds..."
    sleep 2
  fi
done

if [ $attempt -eq $max_attempts ]; then
  echo "Warning: Failed to create replication slot after $max_attempts attempts."
fi

# Verify configuration
echo "Verifying master configuration..."
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -c "SHOW wal_level;"
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -c "SHOW max_wal_senders;"
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -c "SHOW max_replication_slots;"
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -c "SELECT * FROM pg_replication_slots;"
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -c "SELECT * FROM pg_roles WHERE rolname='$REPLICATION_USER';"
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -c "SELECT pg_read_file(current_setting('hba_file'), 0, 1000);"

# Display container IP
echo "IP address PostgreSQL master: $(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $CONTAINER_NAME)"

# Display docker port mappings to verify bindings
echo "Docker port mappings:"
docker port $CONTAINER_NAME

echo "====== PostgreSQL Replication Setup Complete ======"