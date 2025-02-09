#!/bin/bash
# Enhanced SSH Port Changer Script for Debian and Ubuntu
# Version 2.0.0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

trap 'echo -e "${RED}Script interrupted. Exiting...${NC}"; exit 1' SIGINT SIGTERM

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root.${NC}"
    exit 1
fi

# Function to check system requirements
check_requirements() {
    # Check for required commands
    local required_commands=("ss" "systemctl" "sshd" "curl")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${RED}Error: Required command '$cmd' not found.${NC}"
            exit 1
        fi
    done
}

# Detect the SSH service name and status
detect_ssh_service() {
    if systemctl is-active --quiet ssh; then
        echo "ssh"
    elif systemctl is-active --quiet sshd; then
        echo "sshd"
    else
        echo -e "${RED}Error: SSH service is not running.${NC}"
        exit 1
    fi
}

validate_port() {
    local port=$1
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 0 || "$port" -gt 65535 ]]; then
        echo -e "${RED}Invalid port: must be a number between 0 and 65535.${NC}"
        return 1
    elif [[ "$port" -ne 22 && "$port" -lt 1024 ]]; then
        echo -e "${RED}Invalid port: must be 22 or ≥1024.${NC}"
        return 1
    fi
    
    # Check if port is in use
    if ss -tuln | awk '{print $5}' | grep -Eq "[:.]${port}$"; then
        echo -e "${RED}Port $port is already in use.${NC}"
        return 1
    fi
    
    return 0
}

update_firewall() {
    local port=$1
    
    # Handle UFW
    if command -v ufw >/dev/null 2>&1; then
        if ! ufw status | grep -q "$port/tcp"; then
            ufw allow "$port/tcp" || {
                echo -e "${RED}Failed to update UFW rules.${NC}"
                return 1
            }
            echo -e "${GREEN}Port $port allowed in UFW.${NC}"
        fi
    fi
    
    # Handle iptables
    if command -v iptables >/dev/null 2>&1; then
        iptables -A INPUT -p tcp --dport "$port" -j ACCEPT || {
            echo -e "${YELLOW}Warning: Failed to update iptables rules.${NC}"
        }
    fi
}

# Main script execution
main() {
    check_requirements
    SSH_SERVICE=$(detect_ssh_service)
    
    # Get and validate port
    local port
    if [[ -n "$1" ]]; then
        port="$1"
    else
        while true; do
            echo -n "Please enter the desired SSH port > "
            read -r port
            if validate_port "$port"; then
                break
            fi
        done
    fi
    
    # Backup configuration
    local backup_path="/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"
    cp /etc/ssh/sshd_config "$backup_path" || {
        echo -e "${RED}Failed to create backup.${NC}"
        exit 1
    }
    
    # Update SSH configuration
    sed -i.bak "/^[#]*Port /d" /etc/ssh/sshd_config
    echo "Port $port" >> /etc/ssh/sshd_config
    
    # Validate configuration
    if ! sshd -t; then
        echo -e "${RED}Invalid SSH configuration. Restoring backup...${NC}"
        cp "$backup_path" /etc/ssh/sshd_config
        exit 1
    fi
    
    # Update firewall rules
    update_firewall "$port"
    
    # Restart SSH service
    echo -e "${YELLOW}Restarting SSH service in 5 seconds...${NC}"
    sleep 5
    if ! systemctl restart "$SSH_SERVICE"; then
        echo -e "${RED}Failed to restart SSH. Restoring backup...${NC}"
        cp "$backup_path" /etc/ssh/sshd_config
        systemctl restart "$SSH_SERVICE"
        exit 1
    fi
    
    # Display connection information
    local public_ip
    public_ip=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
    echo -e "${GREEN}SSH port successfully changed to $port.${NC}"
    echo -e "Test new connection with:"
    echo -e "ssh -p $port $(whoami)@${public_ip}"
    echo -e "${YELLOW}Note: Keep this terminal open until you verify the new connection works.${NC}"
}

main "$@"
