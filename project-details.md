# Proxmox Application Deployment Script Project

## Overview

This project enhances the Proxmox application deployment scripts by integrating several features from a previous implementation into the new codebase. The scripts automate the creation and configuration of LXC containers in Proxmox VE, with advanced features for network configuration, SSH key management, and infrastructure registration.

## Project Structure

The project is organized into several key files:

1. **Main Script Files**:
   - `/mnt/c/Dev/ProxmoxVE-RIP-tteck/ct/docker.sh`: Main script for setting up an LXC container that runs Docker
   - `/mnt/c/Dev/ProxmoxVE-RIP-tteck/misc/build.func`: Contains functions for building the application being installed
   - `/mnt/c/Dev/ProxmoxVE-RIP-tteck/misc/alpine-install.func`: Function file for setting up containers with Alpine Linux
   - `/mnt/c/Dev/ProxmoxVE-RIP-tteck/misc/install.func`: Function file for setting up containers with Ubuntu or Debian

2. **Configuration Files**:
   - `$HOME/ProxmoxScripts/.ProxmoxHelpers/config.sh`: Contains API credentials and endpoints for Netbox and pfSense

## Implemented Features

### 1. Network and IP Address Selection using Netbox API

- **Implementation**: Enhanced the IP address selection in `build2.func` to provide three options:
  - DHCP: Use DHCP for automatic IP assignment
  - Netbox: Select from available Netbox prefixes
  - Manual: Enter a static IP address manually
- **Details**:
  - Added a `source_config()` function to `build1.func` to source the config.sh file containing API credentials
  - Implemented dynamic retrieval of available IP prefixes from Netbox
  - Added support for manual IP address entry as fallback
- **API Endpoints**:
  - `/api/ipam/prefixes/`: Get a list of prefix objects
  - `/api/ipam/prefixes/{id}/`: Get a prefix object
  - `/api/ipam/prefixes/{id}/available-ips/`: Get available IPs from a prefix

### 2. Intelligent Gateway Selection

- **Implementation**: Restructured the gateway selection in `build2.func` to:
  - First check if Netbox prefix details are available
  - If a gateway is found in the custom fields, present a menu with two options:
    - Use the Netbox gateway
    - Enter a gateway manually
  - Provide proper validation for manually entered gateways
  - Fall back to manual entry if no Netbox gateway is available
- **Details**:
  - Gateway information is retrieved from the Netbox API in the custom_fields.Gateways field of the prefix object
  - The gateway is extracted from the CIDR notation if needed

### 3. VLAN Configuration

- **Implementation**: Restructured the VLAN selection in `build2.func` to:
  - First check if Netbox prefix details are available
  - If a VLAN is found in the prefix details, present a menu with two options:
    - Use the Netbox VLAN
    - Enter a VLAN manually
  - Fall back to manual entry if no Netbox VLAN is available
  - Support manual VLAN entry as fallback
- **Details**:
  - Added special handling for VLAN 1:
    - If VLAN 1 is selected (either from Netbox or manually), it will NOT tag the network interface
    - This ensures that VLAN 1 is treated as the default untagged VLAN
    - The display shows "Default (VLAN 1)" to indicate this special handling
- **API Endpoints**:
  - `/api/ipam/vlans/`: Get a list of VLAN objects
  - `/api/ipam/vlans/{id}/`: Get a VLAN object

### 4. SSH Public Key Injection

- **Implementation**: Enhanced the SSH key selection in `build2.func` to:
  - Present a menu with two options when SSH is enabled:
    - Get SSH keys from GitHub username
    - Enter SSH key manually
  - Store the selection and GitHub username for later use
- **Details**:
  - Modified the `setup_ssh_keys()` function in `build3.func` to:
    - Use the SSH key source selection from advanced settings
    - Handle both GitHub keys and manually entered keys
    - Download SSH keys from GitHub when that option is selected
    - Add the keys to the root user's authorized_keys file
  - Added export for the SSH_KEY_SOURCE variable to ensure it's available to the setup_ssh_keys function

### 5. Infrastructure Registration

- **Implementation**: Added a `register_infrastructure()` function to `build3.func` that:
  - Registers the new container in Netbox inventory
  - Adds a firewall alias to pfSense
  - Creates a DNS resolver entry in pfSense
- **Details**:
  - Enhanced the hostname handling in `build2.func` to:
    - Store the full FQDN in $HN
    - Parse out $SHORTHOST (hostname without domain) and $DOMAIN1 (domain portion)
    - Handle both cases: when a user enters a hostname with or without a domain
    - Display full hostname, short hostname, and domain information to the user
    - Prompt for domain when needed and construct the full FQDN
  - Added a `parse_hostname()` function to `build1.func` to:
    - Provide a consistent way to extract short hostname and domain from a full hostname
    - Ensure proper parsing regardless of the number of subdomains present
  - Modified the `register_infrastructure` function to handle empty domain names gracefully
  - Added export for the DOMAIN1 and SHORTHOST variables to ensure they're available to the register_infrastructure function

### 6. Tenant Selection for Netbox IP Registration

- **Implementation**: Enhanced the `register_infrastructure()` function in `build3.func` to:
  - Fetch available tenants from Netbox API
  - Present a menu to the user to select a tenant for the IP address
  - Include the selected tenant ID in the Netbox API call when registering the IP
  - Handle cases where no tenants exist or the user chooses not to assign a tenant
  - Display appropriate success messages based on tenant assignment
- **API Endpoints**:
  - `/api/tenancy/tenants/`: Get a list of tenant objects
  - `/api/tenancy/tenants/{id}/`: Get a tenant object

## Architecture

The script architecture follows a modular approach with clear separation of concerns:

1. **Main Script (`docker.sh`)**: Entry point that calls the build functions
2. **Build Functions (`build.func`)**: Core functionality for container creation and configuration
3. **Installation Functions (`alpine-install.func`, `install.func`)**: OS-specific installation procedures
4. **Configuration Source (`config.sh`)**: External configuration for API credentials and endpoints

The flow of execution is as follows:

1. User runs the main script (`docker.sh`)
2. Script sources the build functions (`build.func`)
3. User selects settings (default or advanced)
4. If advanced settings are selected, the user is prompted for various configuration options
5. The container is created with the specified settings
6. OS-specific installation is performed
7. SSH keys are set up if enabled
8. Infrastructure registration is performed if not using DHCP

## API Integration

The script integrates with several APIs:

1. **Netbox API**:
   - Used for retrieving available IP prefixes, VLANs, and tenants
   - Used for registering the container's IP address in the inventory
   - Authentication via token in the config.sh file

2. **pfSense API**:
   - Used for adding a firewall alias
   - Used for creating a DNS resolver entry
   - Authentication via API key in the config.sh file

3. **GitHub API**:
   - Used for retrieving SSH public keys for a given username
   - No authentication required for public keys

## Configuration Requirements

The script requires the following configuration:

1. **API Credentials**:
   - Netbox API address and token
   - pfSense API address and token

2. **Container Settings**:
   - OS type and version
   - Container ID
   - Hostname and domain
   - Disk size, CPU cores, and RAM
   - Network settings (bridge, IP address, gateway, VLAN)
   - SSH access settings

## Future Enhancements

Potential future enhancements for the script include:

1. **Error Handling Improvements**:
   - More robust error handling for API calls
   - Better feedback for failed operations

2. **Additional API Integrations**:
   - Integration with other infrastructure management systems
   - Support for additional authentication methods

3. **User Interface Enhancements**:
   - Improved menu navigation
   - Progress indicators for long-running operations

4. **Feature Additions**:
   - Support for additional container configurations
   - Integration with container orchestration systems
   - Support for container templates

## Usage Instructions

To use the script:

1. Ensure the config.sh file is properly configured with API credentials
2. Run the main script: `bash /mnt/c/Dev/ProxmoxVE-RIP-tteck/ct/docker.sh`
3. Follow the prompts to configure the container
4. The script will create and configure the container according to the specified settings

## Troubleshooting

Common issues and their solutions:

1. **API Connection Failures**:
   - Check that the API credentials in config.sh are correct
   - Ensure the API endpoints are accessible from the Proxmox host

2. **Container Creation Failures**:
   - Check that the Proxmox host has sufficient resources
   - Ensure the container ID is not already in use

3. **Network Configuration Issues**:
   - Verify that the specified bridge exists
   - Check that the IP address is not already in use
   - Ensure the gateway is correct for the specified network

## Conclusion

The enhanced Proxmox application deployment scripts provide a powerful and flexible way to create and configure LXC containers in Proxmox VE. The integration with Netbox and pfSense APIs allows for automated infrastructure management, while the SSH key injection feature provides secure access to the containers.