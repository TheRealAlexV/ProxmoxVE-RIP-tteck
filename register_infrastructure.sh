#!/bin/bash

# Script to manually register a Proxmox container or VM in infrastructure systems
# Based on the register_infrastructure() function in build3.func

# Color codes
CL="\e[0m"
DF="\e[39m"
RD="\e[31m"
GN="\e[32m"
YW="\e[33m"
BL="\e[34m"
MG="\e[35m"
CY="\e[36m"
WH="\e[37m"

# Message functions
msg_info() {
    echo -e "${BL}[INFO]${DF} $1${CL}"
}

msg_ok() {
    echo -e "${GN}[OK]${DF} $1${CL}"
}

msg_error() {
    echo -e "${RD}[ERROR]${DF} $1${CL}"
}

# Function to source configuration file
source_config() {
    CONFIG_FILE="$HOME/ProxmoxScripts/.ProxmoxHelpers/config.sh"
    
    if [ -f "$CONFIG_FILE" ]; then
        msg_info "Sourcing configuration from $CONFIG_FILE"
        source "$CONFIG_FILE"
        return 0
    else
        msg_info "Configuration file not found at $CONFIG_FILE"
        return 1
    fi
}

# Function to parse hostname into short hostname and domain
parse_hostname() {
    local full_hostname="$1"
    
    # Extract short hostname (part before first dot)
    SHORTHOST=$(echo "$full_hostname" | cut -d. -f1)
    
    # Extract domain (everything after first dot)
    DOMAIN1=$(echo "$full_hostname" | cut -d. -f2- | grep -v "^$SHORTHOST$")
    
    # If domain is empty, prompt for it
    if [ -z "$DOMAIN1" ]; then
        read -p "Enter domain name (or leave empty for no domain): " DOMAIN1
    fi
    
    # Display parsed hostname components
    msg_info "Hostname components:"
    echo "  Full hostname: $full_hostname"
    echo "  Short hostname: $SHORTHOST"
    echo "  Domain: ${DOMAIN1:-<none>}"
}

# Function to detect if ID is for a container or VM
detect_resource_type() {
    local ID=$1
    
    # Check if it's a container
    if pct status $ID &>/dev/null; then
        echo "container"
        return 0
    fi
    
    # Check if it's a VM
    if qm status $ID &>/dev/null; then
        echo "vm"
        return 0
    fi
    
    # Not found
    echo "unknown"
    return 1
}

# Function to get IP address from a container
get_container_ip() {
    local CTID=$1
    local IP=$(pct exec "$CTID" ip a s dev eth0 | awk '/inet / {print $2}' | cut -d/ -f1)
    local CIDR=$(pct exec "$CTID" ip a s dev eth0 | awk '/inet / {print $2}' | grep -o '/[0-9]*')
    echo "$IP$CIDR"
}

# Function to get IP address from a VM
get_vm_ip() {
    local VMID=$1
    # Try to get IP from qm guest agent info
    local IP=$(qm guest cmd $VMID network-get-interfaces | jq -r '.[] | select(.name | test("eth0|ens|eno|enp")) | .["ip-addresses"][] | select(."ip-address-type" == "ipv4") | ."ip-address"' 2>/dev/null)
    
    if [ -z "$IP" ]; then
        # Fallback to qm agent get-host-name-interfaces
        IP=$(qm agent $VMID network-get-interfaces | jq -r '.[] | select(.name | test("eth0|ens|eno|enp")) | .["ip-addresses"][] | select(."ip-address-type" == "ipv4") | ."ip-address"' 2>/dev/null)
    fi
    
    # Default CIDR if we can't determine it
    echo "$IP/24"
}

# Function to register the resource in infrastructure systems
register_infrastructure() {
    local ID=$1
    
    # Detect if it's a container or VM
    RESOURCE_TYPE=$(detect_resource_type $ID)
    
    if [ "$RESOURCE_TYPE" == "container" ]; then
        msg_info "Registering infrastructure for container ID: $ID"
        
        # Check if container is running
        if [ "$(pct status $ID | awk '{print $2}')" != "running" ]; then
            msg_info "Container $ID is not running. Starting it now..."
            pct start $ID
            sleep 5  # Give it time to start
        fi
        
        # Get container hostname
        HOSTNAME=$(pct exec $ID hostname)
        
        # Get container IP address and network
        NET=$(get_container_ip $ID)
        
        # Get network name from container config
        NETNAME=$(pct config $ID | grep -oP 'net0:.*bridge=\K[^,]*' | sed -E 's/vmbr//g')
    elif [ "$RESOURCE_TYPE" == "vm" ]; then
        msg_info "Registering infrastructure for VM ID: $ID"
        
        # Check if VM is running
        if [ "$(qm status $ID | awk '{print $2}')" != "running" ]; then
            msg_info "VM $ID is not running. Starting it now..."
            qm start $ID
            sleep 15  # Give it more time to start and initialize guest agent
        fi
        
        # Check if QEMU guest agent is running
        if ! qm agent $ID ping &>/dev/null; then
            msg_error "QEMU guest agent not responding in VM $ID. Please ensure it's installed and running."
            msg_info "For Debian/Ubuntu: apt-get install qemu-guest-agent"
            msg_info "For CentOS/RHEL: yum install qemu-guest-agent"
            msg_info "Then enable and start the service: systemctl enable qemu-guest-agent && systemctl start qemu-guest-agent"
            return 1
        fi
        
        # Get VM hostname
        HOSTNAME=$(qm agent $ID get-host-name | jq -r '.["host-name"]')
        
        # Get VM IP address and network
        NET=$(get_vm_ip $ID)
        
        # Get network name from VM config
        NETNAME=$(qm config $ID | grep -oP 'net0:.*bridge=\K[^,]*' | sed -E 's/vmbr//g')
    else
        msg_error "Resource with ID $ID not found or not supported"
        return 1
    fi
    
    # Parse hostname
    parse_hostname "$HOSTNAME"
    
    # Extract IP from NET
    IP=$(echo $NET | cut -d/ -f1)
    
    if [ -z "$IP" ]; then
        msg_error "Could not determine IP address"
        return 1
    fi
    
    # Source configuration file
    if ! source_config; then
        # Prompt for API credentials if config file not found
        read -p "Enter Netbox API address (e.g., https://netbox.example.com): " NBADDR
        read -p "Enter Netbox API token: " NBTOKEN
        read -p "Enter pfSense API address (e.g., https://pfsense.example.com): " PFADDR
        read -p "Enter pfSense API token: " PFTOKEN
        
        # Save credentials for future use
        read -p "Save these credentials for future use? (y/n): " SAVE_CREDS
        if [[ $SAVE_CREDS =~ ^[Yy]$ ]]; then
            mkdir -p "$(dirname "$CONFIG_FILE")"
            cat > "$CONFIG_FILE" <<EOF
# API credentials for Proxmox Helper Scripts
NBADDR="$NBADDR"
NBTOKEN="$NBTOKEN"
PFADDR="$PFADDR"
PFTOKEN="$PFTOKEN"
EOF
            chmod 600 "$CONFIG_FILE"
            msg_ok "Saved credentials to $CONFIG_FILE"
        fi
    fi
    
    # Check if API credentials are available
    if [ -z "$NBADDR" ] || [ -z "$NBTOKEN" ] || [ -z "$PFADDR" ] || [ -z "$PFTOKEN" ]; then
        msg_error "API credentials not found. Infrastructure registration skipped."
        return 1
    fi
    
    # Get available tenants from Netbox
    msg_info "Fetching available tenants from Netbox"
    TENANTS_JSON=$(curl -s -X GET \
        -H "Authorization: Token $NBTOKEN" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json; indent=4" \
        "$NBADDR/api/tenancy/tenants/")
    
    # Extract tenant information for display
    TENANTS_COUNT=$(echo "$TENANTS_JSON" | jq '.count')
    
    if [ -z "$TENANTS_COUNT" ] || [ "$TENANTS_COUNT" = "null" ]; then
        msg_error "Failed to fetch tenants from Netbox. Check your API credentials."
        return 1
    fi
    
    msg_ok "Fetched tenant information"
    
    if [ "$TENANTS_COUNT" -eq 0 ]; then
        msg_info "No tenants found in Netbox. Proceeding without tenant assignment."
        TENANT_ID=""
    else
        # Create menu options for tenants
        echo "Available tenants:"
        echo "0) No Tenant (Default)"
        
        for ((i=0; i<$TENANTS_COUNT; i++)); do
            TENANT_ID=$(echo "$TENANTS_JSON" | jq -r ".results[$i].id")
            TENANT_NAME=$(echo "$TENANTS_JSON" | jq -r ".results[$i].name")
            TENANT_DESCRIPTION=$(echo "$TENANTS_JSON" | jq -r ".results[$i].description // \"\"")
            
            if [ -n "$TENANT_DESCRIPTION" ]; then
                echo "$TENANT_ID) $TENANT_NAME ($TENANT_DESCRIPTION)"
            else
                echo "$TENANT_ID) $TENANT_NAME"
            fi
        done
        
        # Get tenant selection
        read -p "Select a tenant ID (or 0 for none): " TENANT_ID
        
        if [ "$TENANT_ID" == "0" ] || [ -z "$TENANT_ID" ]; then
            msg_info "No tenant selected. Proceeding without tenant assignment."
            TENANT_ID=""
        fi
    fi
    
    # Prepare DNS name for Netbox
    local dns_name=""
    if [ -n "$DOMAIN1" ]; then
        dns_name="\"dns_name\": \"$SHORTHOST.$DOMAIN1\""
    fi
    
    # Prepare Netbox data
    if [ -n "$dns_name" ] && [ -n "$TENANT_ID" ]; then
        NETBOX_DATA=$(cat <<EOF
{
  "address": "$NET",
  $dns_name,
  "tenant": $TENANT_ID
}
EOF
)
    elif [ -n "$dns_name" ]; then
        NETBOX_DATA=$(cat <<EOF
{
  "address": "$NET",
  $dns_name
}
EOF
)
    elif [ -n "$TENANT_ID" ]; then
        NETBOX_DATA=$(cat <<EOF
{
  "address": "$NET",
  "tenant": $TENANT_ID
}
EOF
)
    else
        # No domain, just use the IP address
        msg_info "No domain specified, using IP address only for Netbox"
        NETBOX_DATA="{\"address\": \"$NET\"}"
    fi
    
    # Register in Netbox
    msg_info "Adding host to Netbox"
    
    NETBOX_RESPONSE=$(curl -s -X POST \
        -H "Authorization: Token $NBTOKEN" \
        -H "Content-Type: application/json" \
        "$NBADDR/api/ipam/ip-addresses/" \
        --data "$NETBOX_DATA")
    
    if echo "$NETBOX_RESPONSE" | grep -q "\"id\""; then
        if [ -n "$TENANT_ID" ]; then
            msg_ok "Added host to Netbox with tenant ID: $TENANT_ID"
        else
            msg_ok "Added host to Netbox without tenant assignment"
        fi
    else
        msg_error "Failed to add host to Netbox: $(echo "$NETBOX_RESPONSE" | grep -o '"detail":"[^"]*"' || echo 'Unknown error')"
    fi
    
    # Register in pfSense DNS
    if [ -n "$DOMAIN1" ] && [ -n "$SHORTHOST" ]; then
        msg_info "Adding host to pfSense DNS"
        # Extract IP without CIDR
        IP_ADDR=$(echo $NET | cut -d "/" -f1)
        
        DNS_RESPONSE=$(curl -k -s -X 'POST' \
            "$PFADDR/api/v2/services/dns_resolver/host_override" \
            -H "X-API-Key: $PFTOKEN" \
            -H 'accept: application/json' \
            -H 'Content-Type: application/json' \
            --data "{\"apply\": true, \"domain\": \"$DOMAIN1\", \"host\": \"$SHORTHOST\", \"ip\": [\"$IP_ADDR\"]}")
        
        if echo "$DNS_RESPONSE" | grep -q '"code":200'; then
            msg_ok "Added host to pfSense DNS"
        else
            msg_error "Failed to add host to pfSense DNS: $(echo "$DNS_RESPONSE" | grep -o '"message":"[^"]*"' || echo 'Unknown error')"
        fi
    else
        msg_info "No domain specified, skipping pfSense DNS registration"
    fi
    
    # Register in pfSense firewall aliases
    msg_info "Adding host to pfSense firewall aliases"
    # Extract IP without CIDR
    IP_ADDR=$(echo $NET | cut -d "/" -f1)
    
    if [ -z "$NETNAME" ]; then
        NETNAME="default"
    fi
    
    # Create alias name using short hostname and filtered network name
    # Extract the label part from NETNAME (remove VLAN number and period)
    if [ -n "$NETNAME" ]; then
        # If NETNAME contains a period, extract the part after the period
        FILTERED_NETNAME=$(echo "$NETNAME" | sed -E 's/^[0-9]+\.//g')
    else
        FILTERED_NETNAME="default"
    fi
    ALIAS_NAME="infra_${SHORTHOST}_${FILTERED_NETNAME}"
    
    # Create a description for the alias
    ALIAS_DESCR="Infrastructure host: ${SHORTHOST}"
    if [ -n "$DOMAIN1" ]; then
        ALIAS_DESCR="${ALIAS_DESCR}.${DOMAIN1}"
    fi
    
    # Prepare the JSON payload
    ALIAS_DATA="{\"address\": [\"$IP_ADDR\"], \"apply\": true, \"name\": \"$ALIAS_NAME\", \"type\": \"host\", \"descr\": \"$ALIAS_DESCR\"}"
    
    # Make the API call and capture the response
    ALIAS_RESPONSE=$(
    curl -k -s -X 'POST' \
        "$PFADDR/api/v2/firewall/alias" \
        -H "X-API-Key: $PFTOKEN" \
        -H 'accept: application/json' \
        -H 'Content-Type: application/json' \
        --data "$ALIAS_DATA")
    
    # Check if the response contains a success code
    if echo "$ALIAS_RESPONSE" | grep -q '"code":200'; then
        msg_ok "Added host to pfSense firewall aliases"
    else
        msg_error "Failed to add host to pfSense firewall aliases: $(echo "$ALIAS_RESPONSE" | grep -o '"message":"[^"]*"' || echo 'Unknown error')"
    fi
    
    msg_ok "Infrastructure registration completed"
}

# Main script execution
if [ $# -eq 0 ]; then
    echo "Usage: $0 <id>"
    echo "Example: $0 100 (for container or VM with ID 100)"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    msg_error "jq is required but not installed. Please install it first."
    echo "On Debian/Ubuntu: apt install jq"
    echo "On CentOS/RHEL: yum install jq"
    exit 1
fi

# Check if pct command is available
if ! command -v pct &> /dev/null; then
    msg_error "pct command not found. This script must be run on a Proxmox host."
    exit 1
fi

# Check if qm command is available
if ! command -v qm &> /dev/null; then
    msg_error "qm command not found. This script must be run on a Proxmox host."
    exit 1
fi

# Call the register_infrastructure function with the provided ID
register_infrastructure "$1"