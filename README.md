# proxmox-nat-manager
## IPv4 NAT Manager for Proxmox VE 8 Servers with a singluar Public IP address

- JQ & iptables-persistant must be installed on the Proxmox Hypervisor
- Qemu-guest-agent must be installed on any Guest VM you intend to forward ports too.
- Hypervisor must be using a linux bridge called `vmbr0`
- Only tested using a Proxmox SNAT Simple Zone - https://pve.proxmox.com/wiki/Setup_Simple_Zone_With_SNAT_and_DHCP


Run the script within directly on the Proxmox Hypervisor.
