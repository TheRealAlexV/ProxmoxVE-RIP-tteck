#!/bin/bash

# Script to delete an LXC container and its related infrastructure entries in Netbox and pfSense
# Usage: ./delete_lxc.sh <container_id>

# Color and formatting variables
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Function to display messages
msg_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

msg_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

msg_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

msg_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if container ID is provided
if [ -z "$1" ]; then
    msg_error "Container ID not provided"
    echo "Usage: $0 <container_id>"
    exit 1
fi

CTID="$1"

# Source the configuration file
CONFIG_FILE="$HOME/ProxmoxScripts/.ProxmoxHelpers/config.sh"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    msg_ok "Configuration loaded from $CONFIG_FILE"
else
    msg_error "Configuration file not found at $CONFIG_FILE"
    msg_info "Creating a sample configuration file..."
    
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" << EOF
# Netbox API configuration
NBADDR="https://netbox.example.com"
NBTOKEN="your_netbox_token"

# pfSense API configuration
PFADDR="https://pfsense.example.com"
PFTOKEN="your_pfsense_token"
EOF
    
    msg_warn "Please edit $CONFIG_FILE with your API credentials"
    exit 1
fi

# Check if required variables are set
if [ -z "$NBADDR" ] || [ -z "$NBTOKEN" ] || [ -z "$PFADDR" ] || [ -z "$PFTOKEN" ]; then
    msg_error "API credentials not found in $CONFIG_FILE"
    msg_info "Please ensure the following variables are set:"
    echo "NBADDR - Netbox API address"
    echo "NBTOKEN - Netbox API token"
    echo "PFADDR - pfSense API address"
    echo "PFTOKEN - pfSense API token"
    exit 1
fi

# Check if container exists
if ! pct status "$CTID" &>/dev/null; then
    msg_error "Container $CTID does not exist"
    exit 1
fi

# Get container information
msg_info "Getting information for container $CTID"
CONTAINER_CONFIG=$(pct config "$CTID" 2>/dev/null)
if [ $? -ne 0 ]; then
    msg_error "Failed to get container configuration"
    exit 1
fi

# Extract hostname and IP address
HOSTNAME=$(echo "$CONTAINER_CONFIG" | grep -oP 'hostname: \K.*')
IP_WITH_CIDR=$(echo "$CONTAINER_CONFIG" | grep -oP 'net0:.*ip=\K[^,]*')
IP_ADDR=$(echo "$IP_WITH_CIDR" | cut -d/ -f1)

if [ -z "$IP_ADDR" ]; then
    msg_warn "Could not determine container IP address from config"
    # Try to get IP from running container
    if pct status "$CTID" | grep -q running; then
        IP_ADDR=$(pct exec "$CTID" -- ip -4 addr show dev eth0 | grep -oP 'inet \K[^/]*')
        if [ -z "$IP_ADDR" ]; then
            msg_warn "Could not determine container IP address from running container"
        fi
    fi
fi

# Parse hostname to get short hostname and domain
parse_hostname() {
    local full_hostname="$1"
    local short_hostname
    local domain
    
    # Extract the first part of the hostname (before the first dot)
    short_hostname=$(echo "$full_hostname" | cut -d. -f1)
    
    # Extract the domain (everything after the first dot)
    if [[ "$full_hostname" == *"."* ]]; then
        domain=$(echo "$full_hostname" | cut -d. -f2-)
    else
        domain=""
    fi
    
    echo "$short_hostname $domain"
}

# Parse the hostname
if [ -n "$HOSTNAME" ]; then
    read SHORTHOST DOMAIN1 <<< $(parse_hostname "$HOSTNAME")
else
    SHORTHOST=""
    DOMAIN1=""
fi

# Display container information
msg_info "Container details:"
echo "  ID: $CTID"
echo "  Hostname: $HOSTNAME"
if [ -n "$SHORTHOST" ]; then
    echo "  Short hostname: $SHORTHOST"
fi
if [ -n "$DOMAIN1" ]; then
    echo "  Domain: $DOMAIN1"
fi
if [ -n "$IP_ADDR" ]; then
    echo "  IP Address: $IP_ADDR"
fi

# Confirm deletion
read -p "Are you sure you want to delete this container and its infrastructure entries? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    msg_info "Operation cancelled"
    exit 0
fi

# Step 1: Delete from Netbox
if [ -n "$IP_ADDR" ]; then
    msg_info "Searching for IP address in Netbox"
    
    # Search for the IP address in Netbox
    NETBOX_SEARCH=$(curl -s -X GET \
        -H "Authorization: Token $NBTOKEN" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json; indent=4" \
        "$NBADDR/api/ipam/ip-addresses/?address=$IP_ADDR")
    
    IP_COUNT=$(echo "$NETBOX_SEARCH" | jq '.count')
    
    if [ "$IP_COUNT" -gt 0 ]; then
        # Extract the IP address ID
        IP_ID=$(echo "$NETBOX_SEARCH" | jq -r '.results[0].id')
        
        if [ -n "$IP_ID" ] && [ "$IP_ID" != "null" ]; then
            msg_info "Deleting IP address $IP_ADDR (ID: $IP_ID) from Netbox"
            
            # Delete the IP address
            NETBOX_DELETE=$(curl -s -X DELETE \
                -H "Authorization: Token $NBTOKEN" \
                -H "Content-Type: application/json" \
                "$NBADDR/api/ipam/ip-addresses/$IP_ID/")
            
            if [ -z "$NETBOX_DELETE" ]; then
                msg_ok "Successfully deleted IP address from Netbox"
            else
                msg_error "Failed to delete IP address from Netbox: $NETBOX_DELETE"
            fi
        else
            msg_warn "Could not determine Netbox IP address ID"
        fi
    else
        msg_warn "IP address $IP_ADDR not found in Netbox"
    fi
else
    msg_warn "No IP address available, skipping Netbox deletion"
fi

# Step 2: Delete from pfSense DNS
if [ -n "$SHORTHOST" ] && [ -n "$DOMAIN1" ]; then
    msg_info "Searching for DNS entries in pfSense"
    
    # Get all DNS overrides
    DNS_OVERRIDES=$(curl -k -s -X GET \
        "$PFADDR/api/v2/services/dns_resolver/host_override" \
        -H "X-API-Key: $PFTOKEN" \
        -H "accept: application/json")
    
    # Check if we got a valid response
    if [ $? -eq 0 ] && [ -n "$DNS_OVERRIDES" ]; then
        # Find entries matching our hostname and domain
        DNS_IDS=$(echo "$DNS_OVERRIDES" | jq -r ".data[] | select(.host == \"$SHORTHOST\" and .domain == \"$DOMAIN1\") | .id")
        
        if [ -n "$DNS_IDS" ]; then
            for DNS_ID in $DNS_IDS; do
                msg_info "Deleting DNS entry for $SHORTHOST.$DOMAIN1 (ID: $DNS_ID) from pfSense"
                
                # Delete the DNS entry
                # Use the correct endpoint with id as a query parameter
                DNS_DELETE=$(curl -k -s -X DELETE \
                    "$PFADDR/api/v2/services/dns_resolver/host_override?id=$DNS_ID&apply=true" \
                    -H "X-API-Key: $PFTOKEN" \
                    -H "accept: application/json")
                
                if echo "$DNS_DELETE" | grep -q '"code":200'; then
                    msg_ok "Successfully deleted DNS entry from pfSense"
                else
                    msg_error "Failed to delete DNS entry from pfSense: $(echo "$DNS_DELETE" | grep -o '"message":"[^"]*"' || echo 'Unknown error')"
                fi
            done
        else
            msg_warn "No DNS entries found for $SHORTHOST.$DOMAIN1 in pfSense"
        fi
    else
        msg_error "Failed to retrieve DNS entries from pfSense"
    fi
else
    msg_warn "No hostname or domain available, skipping pfSense DNS deletion"
fi

# Step 3: Delete from pfSense firewall aliases
if [ -n "$SHORTHOST" ]; then
    msg_info "Searching for firewall aliases in pfSense"
    
    # Get all aliases
    ALIASES=$(curl -k -s -X GET \
        "$PFADDR/api/v2/firewall/alias" \
        -H "X-API-Key: $PFTOKEN" \
        -H "accept: application/json")
    
    # Check if we got a valid response
    if [ $? -eq 0 ] && [ -n "$ALIASES" ]; then
        # Find aliases matching our hostname pattern
        ALIAS_PATTERN="infra_${SHORTHOST}_"
        ALIAS_NAMES=$(echo "$ALIASES" | jq -r ".data[] | select(.name | startswith(\"$ALIAS_PATTERN\")) | .name")
        
        if [ -n "$ALIAS_NAMES" ]; then
            for ALIAS_NAME in $ALIAS_NAMES; do
                msg_info "Deleting firewall alias $ALIAS_NAME from pfSense"
                
                # Delete the alias
                # Use the correct endpoint with id as a query parameter
                ALIAS_DELETE=$(curl -k -s -X DELETE \
                    "$PFADDR/api/v2/firewall/alias?id=$ALIAS_NAME&apply=true" \
                    -H "X-API-Key: $PFTOKEN" \
                    -H "accept: application/json")
                
                if echo "$ALIAS_DELETE" | grep -q '"code":200'; then
                    msg_ok "Successfully deleted firewall alias from pfSense"
                else
                    msg_error "Failed to delete firewall alias from pfSense: $(echo "$ALIAS_DELETE" | grep -o '"message":"[^"]*"' || echo 'Unknown error')"
                fi
            done
            
            msg_ok "All firewall aliases for $SHORTHOST deleted and changes applied"
        else
            msg_warn "No firewall aliases found for $SHORTHOST in pfSense"
        fi
    else
        msg_error "Failed to retrieve firewall aliases from pfSense"
    fi
else
    msg_warn "No hostname available, skipping pfSense firewall alias deletion"
fi

# Step 4: Delete the LXC container
msg_info "Stopping container $CTID"
pct stop "$CTID" &>/dev/null

# Wait for container to stop
for i in {1..10}; do
    if ! pct status "$CTID" | grep -q running; then
        break
    fi
    sleep 1
done

# Force stop if still running
if pct status "$CTID" | grep -q running; then
    msg_warn "Container still running, forcing stop"
    pct stop "$CTID" --force &>/dev/null
    sleep 2
fi

msg_info "Deleting container $CTID"
pct destroy "$CTID" &>/dev/null

if [ $? -eq 0 ]; then
    msg_ok "Container $CTID successfully deleted"
else
    msg_error "Failed to delete container $CTID"
    exit 1
fi

msg_ok "Container and infrastructure entries cleanup completed"