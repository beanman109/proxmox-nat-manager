#!/bin/bash
# NAT Port Forwarding Manager for Proxmox VE 8
# This updated script automatically fetches the private IP address of a VM using the QEMU guest agent.
# It provides an interactive menu to view, add, and remove NAT port forwarding rules.
# Rules are stored in a persistent file: /etc/port_forwarding_rules.conf
# Run this script as root.
# IMPORTANT!!! Install iptables-persistent & jq otherwise script will not run and rules will not persist
# Install iptables-persistent to make rules persist through reboot
# Install jq to give script ability to parse private IP address from each VM
# READ THE ABOVE 3 LINES

RULES_FILE="/etc/port_forwarding_rules.conf"
BRIDGE="vmbr0"

# Ensure persistent file exists.
if [ ! -f "$RULES_FILE" ]; then
    touch "$RULES_FILE"
fi

# Function to update iptables persistence (adjust as needed).
update_persistence() {
    iptables-save > /etc/iptables/rules.v4
}

# Get the VM name using its VMID.
get_vm_name() {
    local vmid=$1
    if [ -z "$vmid" ]; then
        echo "N/A"
    else
        local name
        name=$(qm list | awk -v id="$vmid" '$1==id {print $2}')
        if [ -z "$name" ]; then
            echo "Unknown"
        else
            echo "$name"
        fi
    fi
}

# List VMs for selection.
list_vms() {
    echo "Available VMs (must be running with QEMU guest agent enabled):"
    # Skip the header line and show VMID and Name.
    qm list | tail -n +2 | awk '{print NR") VMID:" $1 " - " $2}'
}

# Function to fetch the primary IPv4 address of a VM via guest agent.
fetch_vm_ip() {
    local vmid=$1
    # Query the guest agent for network interfaces.
    local output
    output=$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null)
    if [ -z "$output" ]; then
        echo ""
        return
    fi
    # Use jq to extract the first IPv4 address from a non-loopback interface.
    local ip
    ip=$(echo "$output" | jq -r '[.[] 
            | select(.name != "lo") 
            | .["ip-addresses"][]? 
            | select(.["ip-address-type"]=="ipv4" and .["ip-address"] != null)
          ][0]."ip-address"')
    echo "$ip"
}

# View current port forwarding rules.
view_rules() {
    if [ ! -s "$RULES_FILE" ]; then
        echo "No port forwarding rules found."
        return
    fi

    echo "Current NAT Port Forwarding Rules:"
    echo "----------------------------------"
    local index=1
    while IFS=":" read -r external_port protocol dest_ip dest_port vmid; do
        vm_name=$(get_vm_name "$vmid")
        echo "$index) External Port: $external_port, Protocol: $protocol, Destination: ${dest_ip}:${dest_port}, VM ID: ${vmid:-N/A}, VM Name: $vm_name"
        index=$((index+1))
    done < "$RULES_FILE"
}

# Add a new port forwarding rule.
add_rule() {
    # List available VMs.
    list_vms
    echo ""
    read -p "Select a VM by number: " vm_choice

    # Extract the chosen VM from qm list output.
    mapfile -t vm_list < <(qm list | tail -n +2)
    if ! [[ "$vm_choice" =~ ^[0-9]+$ ]] || [ "$vm_choice" -lt 1 ] || [ "$vm_choice" -gt "${#vm_list[@]}" ]; then
        echo "Invalid selection."
        return
    fi

    # Extract the selected VM's ID.
    selected_vm_line=${vm_list[$((vm_choice-1))]}
    vmid=$(echo "$selected_vm_line" | awk '{print $1}')
    vm_name=$(echo "$selected_vm_line" | awk '{print $2}')

    # Fetch the VM's IP address via guest agent.
    vm_ip=$(fetch_vm_ip "$vmid")
    if [ -z "$vm_ip" ]; then
        echo "Failed to fetch the IP address for VM ID $vmid. Ensure the QEMU guest agent is installed and running."
        return
    fi
    echo "Selected VM: $vm_name (ID: $vmid) with IP: $vm_ip"

    read -p "Enter external port: " external_port
    read -p "Enter protocol (tcp/udp): " protocol
    if [[ "$protocol" != "tcp" && "$protocol" != "udp" ]]; then
        echo "Invalid protocol. Only tcp and udp are supported."
        return
    fi
    read -p "Enter destination port on the VM: " dest_port

    # Check for duplicate rule on the same external port and protocol.
    if grep -q "^${external_port}:${protocol}:" "$RULES_FILE"; then
        echo "A rule for external port $external_port with protocol $protocol already exists."
        return
    fi

    # Add iptables DNAT rule.
    iptables -t nat -A PREROUTING -i "$BRIDGE" -p "$protocol" --dport "$external_port" -j DNAT --to-destination "${vm_ip}:${dest_port}"
    if [ $? -ne 0 ]; then
        echo "Failed to add PREROUTING rule."
        return
    fi

    # Add iptables MASQUERADE rule.
    iptables -t nat -A POSTROUTING -o "$BRIDGE" -p "$protocol" -d "$vm_ip" --dport "$dest_port" -j MASQUERADE
    if [ $? -ne 0 ]; then
        echo "Failed to add POSTROUTING rule."
        iptables -t nat -D PREROUTING -i "$BRIDGE" -p "$protocol" --dport "$external_port" -j DNAT --to-destination "${vm_ip}:${dest_port}"
        return
    fi

    # Save rule in the persistent file.
    echo "${external_port}:${protocol}:${vm_ip}:${dest_port}:${vmid}" >> "$RULES_FILE"
    update_persistence
    echo "Port forwarding rule added successfully."
}

# Remove an existing port forwarding rule.
remove_rule() {
    if [ ! -s "$RULES_FILE" ]; then
        echo "No rules to remove."
        return
    fi

    echo "Select the rule number to remove:"
    view_rules
    read -p "Enter rule number: " rule_num

    total=$(wc -l < "$RULES_FILE")
    if ! [[ "$rule_num" =~ ^[0-9]+$ ]] || [ "$rule_num" -lt 1 ] || [ "$rule_num" -gt "$total" ]; then
        echo "Invalid rule number."
        return
    fi

    rule=$(sed -n "${rule_num}p" "$RULES_FILE")
    IFS=":" read -r external_port protocol dest_ip dest_port vmid <<< "$rule"

    iptables -t nat -D PREROUTING -i "$BRIDGE" -p "$protocol" --dport "$external_port" -j DNAT --to-destination "${dest_ip}:${dest_port}"
    if [ $? -ne 0 ]; then
        echo "Failed to remove PREROUTING rule."
    fi
    iptables -t nat -D POSTROUTING -o "$BRIDGE" -p "$protocol" -d "$dest_ip" --dport "$dest_port" -j MASQUERADE
    if [ $? -ne 0 ]; then
        echo "Failed to remove POSTROUTING rule."
    fi

    sed -i "${rule_num}d" "$RULES_FILE"
    update_persistence
    echo "Rule removed successfully."
}

# Main menu loop.
while true; do
    echo ""
    echo "NAT Port Forwarding Manager for Proxmox VE 8"
    echo "-------------------------------------------"
    echo "1) View current port forwarding rules"
    echo "2) Add a new port forwarding rule"
    echo "3) Remove an existing port forwarding rule"
    echo "4) Exit"
    read -p "Enter your choice: " choice
    case $choice in
        1)
            view_rules
            ;;
        2)
            add_rule
            ;;
        3)
            remove_rule
            ;;
        4)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid option. Please try again."
            ;;
    esac
done
