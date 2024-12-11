# List available recipes
default:
    @just --list

# Set some default variables
vm_name := "docker"
vm_cpu := "2"
vm_memory := "4GB"
ssh_opts := "-q -l ubuntu -i .ssh/docker_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
scp_opts := "-q -i .ssh/docker_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Default network settings - can be overridden by .env file or environment variables
default_ip := "10.196.3.155"
vm_ip := env_var_or_default("DOCKER_VM_IP", default_ip)

# Generate a new IP address in the LXD bridge network range
generate-ip:
    #!/usr/bin/env bash
    bridge_ip=$(lxc network get lxdbr0 ipv4.address | cut -d'/' -f1)
    # Get first three octets of bridge IP
    prefix=$(echo $bridge_ip | cut -d'.' -f1-3)
    # Generate random last octet (avoiding .1 which is usually the bridge)
    last_octet=$((RANDOM % 250 + 2))
    suggested_ip="$prefix.$last_octet"
    echo "Suggested IP: $suggested_ip"
    echo "To use this IP, run: export DOCKER_VM_IP=$suggested_ip"
    # Check if IP is available
    if ping -c 1 -W 1 $suggested_ip >/dev/null 2>&1; then
        echo "Warning: IP $suggested_ip appears to be in use"
    else
        echo "IP $suggested_ip appears to be available"
    fi

# Show current network configuration
show-network-config:
    #!/usr/bin/env bash
    echo "Current configuration:"
    echo "VM IP: {{vm_ip}}"
    echo "LXD bridge configuration:"
    lxc network show lxdbr0 | grep -E "ipv4.address|ipv4.nat|ipv4.range"

# Validate IP address format and availability
check-ip ip=vm_ip:
    #!/usr/bin/env bash
    if [[ ! {{ip}} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Error: Invalid IP address format: {{ip}}"
        exit 1
    fi
    if ping -c 1 -W 1 {{ip}} >/dev/null 2>&1; then
        echo "Warning: IP {{ip}} appears to be in use"
        exit 1
    fi
    echo "IP {{ip}} appears to be valid and available"

# Setup SSH keys for the project
setup-keys:
    #!/usr/bin/env bash
    echo "Setting up SSH keys for  project..."
    mkdir -p .ssh
    if [ ! -f .ssh/docker_ed25519 ]; then
        ssh-keygen -t ed25519 -f .ssh/docker_ed25519 -N '' -C "docker@local"
        echo "SSH keys generated in .ssh/docker_ed25519"
    else
        echo "SSH keys already exist in .ssh/docker_ed25519"
    fi
    # Create cloud-init directory if it doesn't exist
    mkdir -p cloud-init
    # Create cloud-init/user-data file
    echo "#cloud-config" > cloud-init/user-data
    echo "users:" >> cloud-init/user-data
    echo "  - default" >> cloud-init/user-data
    echo "  - name: ubuntu" >> cloud-init/user-data
    echo "    gecos: ubuntu" >> cloud-init/user-data
    echo "    shell: /bin/bash" >> cloud-init/user-data
    echo "    sudo: ['ALL=(ALL) NOPASSWD:ALL']" >> cloud-init/user-data
    echo "    ssh_authorized_keys:" >> cloud-init/user-data
    echo "      - $(cat .ssh/docker_ed25519.pub)" >> cloud-init/user-data
    echo "cloud-init/user-data created with new SSH key"

# SSH to the LXC VM
ssh:
    ssh {{ssh_opts}} {{vm_ip}}

# Create static IP profile
create-profile: (check-ip vm_ip)
    #!/usr/bin/env bash
    echo "Creating network profile with IP {{vm_ip}}"
    lxc profile create docker-net || true
    lxc profile device add docker-net root disk pool=default path=/ || true
    lxc profile device add docker-net eth0 nic \
        nictype=bridged \
        parent=lxdbr0 \
        ipv4.address={{vm_ip}} || true

# Delete profile if it exists
delete-profile:
    #!/usr/bin/env bash
    if lxc profile show docker-net >/dev/null 2>&1; then \
        echo "Deleting profile docker-net." && \
        lxc profile delete docker-net; \
    else \
        echo "No profile docker-net found to delete"; \
    fi

# Deploy the LXC VM for Docker
deploy-vm: create-profile
    #!/usr/bin/env bash
    echo "Deploying docker VM"
    lxc launch ubuntu:22.04 {{vm_name}} \
        --vm \
        -c limits.cpu={{vm_cpu}} \
        -c limits.memory={{vm_memory}} \
        --profile docker-net \
        --config=user.user-data="$(cat cloud-init/user-data)"

    echo "VM IP address: {{vm_ip}}"

    echo "Waiting for SSH to be available on {{vm_ip}}"
    while ! nc -zv {{vm_ip}} 22 2>/dev/null; do
        sleep 1
    done
    echo "SSH is now available on {{vm_ip}}"

# Delete VM if it exists
delete-vm:
    #!/usr/bin/env bash
    if lxc info {{vm_name}} >/dev/null 2>&1; then \
        echo "Deleting VM {{vm_name}}." && \
        lxc delete --force {{vm_name}}; \
    else \
        echo "No VM named {{vm_name}} found to delete"; \
    fi

# Install the Docker Daemon on the VM via Ansible and spin up a registry
ansible-docker-install:
    #!/usr/bin/env bash
    ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -b -i ansible/inventory.ini ansible/docker.yaml

# Create ansible directory structure and inventory
create-inventory:
    #!/usr/bin/env bash
    mkdir -p ansible
    echo "[docker_registry]" > ansible/inventory.ini
    echo "registry ansible_host={{vm_ip}} ansible_user=ubuntu ansible_ssh_private_key_file=${PWD}/.ssh/docker_ed25519" >> ansible/inventory.ini
    echo "" >> ansible/inventory.ini
    echo "[all:vars]" >> ansible/inventory.ini
    echo "ansible_python_interpreter=/usr/bin/python3" >> ansible/inventory.ini
    echo "Ansible inventory created at ansible/inventory.ini"

# Clean up everything
clean: delete-vm delete-profile
    #!/usr/bin/env bash
    echo "Cleaning up environment..."
    rm -rf cloud-init

# Update the setup recipe to include proxy setup
setup: clean setup-keys deploy-vm create-inventory ansible-docker-install
    #!/usr/bin/env bash
    echo "Docker setup complete!"
    # Get the host IP address that's reachable
    HOST_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
    echo "Access the vm interface at:"
    echo "  - just ssh"