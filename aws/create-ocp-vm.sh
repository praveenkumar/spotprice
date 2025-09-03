 #!/bin/bash

# OpenShift Container Platform (OCP) VM Creator with Spot Allocation
# Integrates with spot-allocation.sh to create optimally priced VMs for OCP deployment

set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPOT_ALLOCATION_SCRIPT="$SCRIPT_DIR/spot-allocation.sh"

# Default configuration
DEFAULT_OCP_VERSION=${OCP_VERSION:-"4.19.10"}
readonly DEFAULT_VM_NAME_PREFIX="ocp"
readonly DEFAULT_KEY_NAME="ocp-key"
readonly DEFAULT_VOLUME_SIZE="120"
readonly DEFAULT_VOLUME_TYPE="gp3"
readonly DEFAULT_AMI_PATTERN="openshift-local-${DEFAULT_OCP_VERSION}-*"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" >&2; }
log_debug() { [[ "${DEBUG:-}" == "1" ]] && echo -e "${YELLOW}[DEBUG]${NC} $*" >&2 || true; }

# Function to get OCP system requirements based on cluster type
get_ocp_requirements() {
    # Only support single node OpenShift requirements
    echo '{"cpus": 8, "memory": 16, "recommended_types": ["m5.2xlarge", "m5a.2xlarge", "c5.2xlarge"]}'
}

get_rhel_ami_pattern() {
    log_warn "get_rhel_ami_pattern is deprecated: AMI pattern is already set"
    return 0
}

# Function to create or verify SSH key pair
setup_ssh_key() {
    local key_name="$1"
    local region="$2"
    
    log_info "Setting up SSH key pair: $key_name in region $region"
    
    # Check if key pair already exists
   
    local pub_key_file="$HOME/.ssh/${key_name}.pub"
    local pub_key=$(aws ec2 describe-key-pairs --region "$region" --key-names "$key_name" --include-public-key --query 'KeyPairs[0].PublicKey' --output text 2>/dev/null || echo "")

    if [[ -n "$pub_key" && "$pub_key" != "None" ]]; then
        echo "$pub_key" > "$pub_key_file"
        chmod 600 "$pub_key_file"
        log_info "Downloaded existing SSH key pair '$key_name' to $pub_key_file"
        return 0
    fi
    
    local key_file="$HOME/.ssh/${key_name}.pem"

    log_info "Creating new SSH key pair: $key_name"
    
    aws ec2 create-key-pair \
        --region "$region" \
        --key-name "$key_name" \
        --key-type rsa \
        --key-format pem \
        --query 'KeyMaterial' \
        --output text > "$key_file"
    
    chmod 600 "$key_file"
    ssh-keygen -y -f "$key_file" > "$pub_key_file"
    
    log_success "Created SSH key pair '$key_name' and saved to $key_file"
}

# Function to create Elastic IP
create_elastic_ip() {
    local region="$1"
    local vm_name="$2"
    
    log_info "Creating Elastic IP in region $region"
    
    # Allocate new Elastic IP
    local allocation_result
    allocation_result=$(aws ec2 allocate-address \
        --region "$region" \
        --domain vpc \
        --output json)
    
    local allocation_id public_ip
    allocation_id=$(echo "$allocation_result" | jq -r '.AllocationId')
    public_ip=$(echo "$allocation_result" | jq -r '.PublicIp')
    
    if [[ -z "$allocation_id" || "$allocation_id" == "null" ]]; then
        log_error "Failed to allocate Elastic IP"
        return 1
    fi
    
    # Tag the Elastic IP
    aws ec2 create-tags \
        --region "$region" \
        --resources "$allocation_id" \
        --tags "Key=Name,Value=${vm_name}-eip" \
               "Key=Purpose,Value=OpenShift-EIP" >/dev/null
    
    log_success "Created Elastic IP: $public_ip (Allocation ID: $allocation_id)"
    
    # Return JSON with allocation details
    jq -n \
        --arg allocation_id "$allocation_id" \
        --arg public_ip "$public_ip" \
        '{
            allocation_id: $allocation_id,
            public_ip: $public_ip
        }'
}

# Function to associate Elastic IP with instance
associate_elastic_ip() {
    local region="$1"
    local instance_id="$2"
    local allocation_id="$3"
    local public_ip="$4"
    
    log_info "Associating Elastic IP $public_ip with instance $instance_id"
    
    local association_id
    association_id=$(aws ec2 associate-address \
        --region "$region" \
        --instance-id "$instance_id" \
        --allocation-id "$allocation_id" \
        --query 'AssociationId' \
        --output text)
    
    if [[ -z "$association_id" || "$association_id" == "None" ]]; then
        log_error "Failed to associate Elastic IP with instance"
        return 1
    fi
    
    log_success "Associated Elastic IP $public_ip with instance $instance_id (Association ID: $association_id)"
    echo "$association_id"
}

# Function to create or get security group for OCP
setup_security_group() {
    local region="$1"
    local sg_name="$2"
    local vpc_id="${3:-}"
    
    log_info "Setting up security group: $sg_name in region $region"
    
    # Get default VPC if not specified
    if [[ -z "$vpc_id" ]]; then
        vpc_id=$(aws ec2 describe-vpcs \
            --region "$region" \
            --filters "Name=is-default,Values=true" \
            --query 'Vpcs[0].VpcId' \
            --output text 2>/dev/null || echo "")
        
        if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
            log_error "No default VPC found in region $region"
            return 1
        fi
        log_debug "Using default VPC: $vpc_id"
    fi
    
    # Check if security group already exists
    local sg_id
    sg_id=$(aws ec2 describe-security-groups \
        --region "$region" \
        --filters "Name=group-name,Values=$sg_name" "Name=vpc-id,Values=$vpc_id" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || echo "None")
    
    if [[ "$sg_id" != "None" && -n "$sg_id" ]]; then
        log_info "Security group '$sg_name' already exists: $sg_id"
        echo "$sg_id"
        return 0
    fi
    
    # Create new security group
    log_info "Creating security group: $sg_name"
    sg_id=$(aws ec2 create-security-group \
        --region "$region" \
        --group-name "$sg_name" \
        --description "Security group for OpenShift Container Platform VM" \
        --vpc-id "$vpc_id" \
        --query 'GroupId' \
        --output text)
    
    # Add rules for OCP
    log_info "Adding security group rules for OCP..."
    
    # SSH access
    aws ec2 authorize-security-group-ingress \
        --region "$region" \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 >/dev/null
    
    # OCP API server
    aws ec2 authorize-security-group-ingress \
        --region "$region" \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 6443 \
        --cidr 0.0.0.0/0 >/dev/null
    
    # OCP console
    aws ec2 authorize-security-group-ingress \
        --region "$region" \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 443 \
        --cidr 0.0.0.0/0 >/dev/null
    
    # HTTP access
    aws ec2 authorize-security-group-ingress \
        --region "$region" \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 80 \
        --cidr 0.0.0.0/0 >/dev/null
    
    # OCP router default ports
    aws ec2 authorize-security-group-ingress \
        --region "$region" \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 8080 \
        --cidr 0.0.0.0/0 >/dev/null
    
    # Internal cluster communication (wide range for simplicity)
    aws ec2 authorize-security-group-ingress \
        --region "$region" \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 2379-2380 \
        --source-group "$sg_id" >/dev/null
    
    # Kubelet API
    aws ec2 authorize-security-group-ingress \
        --region "$region" \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 10250 \
        --source-group "$sg_id" >/dev/null
    
    # NodePort services range
    aws ec2 authorize-security-group-ingress \
        --region "$region" \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 30000-32767 \
        --cidr 0.0.0.0/0 >/dev/null
    
    log_success "Created security group '$sg_name': $sg_id"
    echo "$sg_id"
}

# Function to generate user data script for cloud-init
generate_user_data() {
    # Arguments:
    #   $1 - PubKey
    #   $2 - Username
    #   $3 - PullSecret
    #   $4 - PassDeveloper
    #   $5 - PassKubeadmin
    #   $6 - PublicIP

    local pubkey="$1"
    local username="$2"
    local pull_secret="$3"
    local pass_developer="$4"
    local pass_kubeadmin="$5"
    local public_ip="$6"

    cat <<EOF
#cloud-config
runcmd:
  - systemctl enable --now kubelet
write_files:
  - path: /home/${username}/.ssh/authorized_keys
    content: |
      ${pubkey}
    owner: ${username}
    permissions: '0600'
  - path: /opt/crc/id_rsa.pub
    content: |
      ${pubkey}
    owner: root:root
    permissions: '0644'
  - content: |
      CRC_CLOUD=1
      CRC_NETWORK_MODE_USER=0
    owner: root:root
    path: /etc/sysconfig/crc-env
    permissions: '0644'
  - path: /opt/crc/pull-secret
    content: |
      ${pull_secret}
    owner: root:root
    permissions: '0644'
  - path: /opt/crc/pass_developer
    content: '${pass_developer}'
    owner: root:root
    permissions: '0644'
  - path: /opt/crc/pass_kubeadmin
    content: '${pass_kubeadmin}'
    owner: root:root
    permissions: '0644'
  - path: /opt/crc/eip
    content: '${public_ip}'
    owner: root:root
    permissions: '0644'
EOF
}

# Function to create the VM using spot pricing
create_ocp_vm() {
    local spot_result="$1"
    local vm_name="$2"
    local key_name="$3"
    local security_group_id="$4"
    local volume_size="$5"
    local volume_type="$6"
    local user_data="$7"
    local allocation_id="$8"
    local eip_public_ip="$9"
    
    # Parse spot allocation result
    local region availability_zone spot_price instance_type
    region=$(echo "$spot_result" | jq -r '.region')
    availability_zone=$(echo "$spot_result" | jq -r '.availability_zone')
    spot_price=$(echo "$spot_result" | jq -r '.spot_price')
    instance_type=$(echo "$spot_result" | jq -r '.primary_instance_type')
    
    log_info "Creating OCP VM with optimal spot allocation:"
    log_info "  Name: $vm_name"
    log_info "  Region: $region"
    log_info "  AZ: $availability_zone"
    log_info "  Instance Type: $instance_type"
    log_info "  Spot Price: \$$spot_price/hour"
    
    # Get latest RHEL AMI for the region
    local ami_pattern="$DEFAULT_AMI_PATTERN"
    log_info "Finding openshiftlocal AMI with pattern: $ami_pattern"
    local ami_id=$(aws ec2 describe-images \
        --region "$region" \
        --filters "Name=name,Values=$ami_pattern" \
                 "Name=architecture,Values=x86_64" \
                 "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text)
    
    if [[ -z "$ami_id" || "$ami_id" == "None" ]]; then
        log_error "Could not find suitable openshiftlocal AMI in region $region"
        return 1
    fi
    
    log_info "Using AMI: $ami_id"
    
    # Create the spot instance request
    log_info "Creating spot instance request..."
    
    # Encode user data
    local user_data_encoded
    user_data_encoded=$(echo "$user_data" | base64 -w 0)
    
    # Create spot instance specification
    local spot_spec
    spot_spec=$(jq -n \
        --arg ami "$ami_id" \
        --arg instance_type "$instance_type" \
        --arg key_name "$key_name" \
        --arg security_group_id "$security_group_id" \
        --argjson volume_size "$volume_size" \
        --arg volume_type "$volume_type" \
        --arg user_data "$user_data_encoded" \
        '{
            ImageId: $ami,
            InstanceType: $instance_type,
            KeyName: $key_name,
            SecurityGroupIds: [$security_group_id],
            UserData: $user_data,
            BlockDeviceMappings: [{
                DeviceName: "/dev/xvda",
                Ebs: {
                    VolumeSize: $volume_size,
                    VolumeType: $volume_type,
                    DeleteOnTermination: true,
                }
            }],
            Monitoring: {
                Enabled: true
            },
            Placement: {
                AvailabilityZone: "'"$availability_zone"'"
            }
        }')
    
    # Submit spot instance request
    local spot_request_id
    spot_request_id=$(aws ec2 request-spot-instances \
        --region "$region" \
        --spot-price "$spot_price" \
        --instance-count 1 \
        --type "one-time" \
        --launch-specification "$spot_spec" \
        --query 'SpotInstanceRequests[0].SpotInstanceRequestId' \
        --output text)
    
    log_success "Spot instance request created: $spot_request_id"
    log_info "Waiting for spot instance to be fulfilled..."
    
    # Wait for spot request to be fulfilled
    local max_wait=300  # 5 minutes
    local wait_time=0
    local instance_id=""
    
    while [[ $wait_time -lt $max_wait && -z "$instance_id" ]]; do
        sleep 10
        wait_time=$((wait_time + 10))
        
        local request_state
        request_state=$(aws ec2 describe-spot-instance-requests \
            --region "$region" \
            --spot-instance-request-ids "$spot_request_id" \
            --query 'SpotInstanceRequests[0].State' \
            --output text 2>/dev/null || echo "pending")
        
        if [[ "$request_state" == "active" ]]; then
            instance_id=$(aws ec2 describe-spot-instance-requests \
                --region "$region" \
                --spot-instance-request-ids "$spot_request_id" \
                --query 'SpotInstanceRequests[0].InstanceId' \
                --output text)
        elif [[ "$request_state" == "failed" || "$request_state" == "cancelled" ]]; then
            log_error "Spot instance request failed or was cancelled"
            return 1
        fi
        
        log_debug "Spot request state: $request_state (waited ${wait_time}s)"
    done
    
    if [[ -z "$instance_id" ]]; then
        log_error "Timeout waiting for spot instance request to be fulfilled"
        return 1
    fi
    
    log_success "Spot instance created: $instance_id"
    
    # Add name tag to instance
    aws ec2 create-tags \
        --region "$region" \
        --resources "$instance_id" \
        --tags "Key=Name,Value=$vm_name" \
               "Key=Purpose,Value=OpenShift-$DEFAULT_OCP_VERSION" \
               "Key=ClusterType,Value=snc" \
               "Key=SpotPrice,Value=$spot_price" >/dev/null
    
    # Wait for instance to be running
    log_info "Waiting for instance to be running..."
    aws ec2 wait instance-running --region "$region" --instance-ids "$instance_id"
    
    # Associate Elastic IP with the instance
    local association_id
    association_id=$(associate_elastic_ip "$region" "$instance_id" "$allocation_id" "$eip_public_ip")
    
    # Use the Elastic IP as our public IP
    public_ip="$eip_public_ip"
    
    log_success "OCP VM created successfully!"
    log_info "Instance Details:"
    log_info "  Instance ID: $instance_id"
    log_info "  Public IP: $public_ip"
    log_info "  Region: $region"
    log_info "  Availability Zone: $availability_zone"
    log_info "  Instance Type: $instance_type"
    log_info "  Spot Price: \$$spot_price/hour"
    
    # Output connection information
    echo ""
    log_success "VM is ready for OCP installation!"
    log_info "Connection details:"
    log_info "  SSH: ssh -i ~/.ssh/${key_name}.pem core@${public_ip}"
    log_info "  Preparation script: /opt/ocp/prepare-install.sh"
    
    # Return structured result
    jq -n \
        --arg instance_id "$instance_id" \
        --arg public_ip "$public_ip" \
        --arg region "$region" \
        --arg az "$availability_zone" \
        --arg instance_type "$instance_type" \
        --argjson spot_price "$spot_price" \
        --arg vm_name "$vm_name" \
        --arg key_name "$key_name" \
        --arg allocation_id "$allocation_id" \
        --arg association_id "$association_id" \
        '{
            instance_id: $instance_id,
            public_ip: $public_ip,
            region: $region,
            availability_zone: $az,
            instance_type: $instance_type,
            spot_price: $spot_price,
            vm_name: $vm_name,
            ssh_command: ("ssh -i ~/.ssh/" + $key_name + ".pem core@" + $public_ip),
            key_file: ("~/.ssh/" + $key_name + ".pem"),
            elastic_ip: {
                allocation_id: $allocation_id,
                association_id: $association_id,
                public_ip: $public_ip
            }
        }'
}

# Function to display usage information
usage() {
    cat << EOF
OpenShift Container Platform VM Creator with Spot Allocation

Usage: $0 [OPTIONS]

REQUIRED OPTIONS:
    -v, --ocp-version VERSION    OpenShift version (e.g., 4.14, 4.15)

OPTIONAL OPTIONS:
    -n, --vm-name NAME           VM name prefix (default: $DEFAULT_VM_NAME_PREFIX)
    -k, --key-name KEY           SSH key pair name (default: $DEFAULT_KEY_NAME)
    -a, --ami-pattern PATTERN    Custom AMI pattern (auto-detected from OCP version)
    -t, --instance-types TYPES   Override instance types (comma-separated)
    -r, --increase-rate RATE     Spot price increase rate % (default: 10)
    --volume-size SIZE           Root volume size in GB (default: $DEFAULT_VOLUME_SIZE)
    --volume-type TYPE           Volume type (default: $DEFAULT_VOLUME_TYPE)
    --pull-secret FILE           Path to OpenShift pull secret file (required for installation)
    -d, --debug                  Enable debug output
    -h, --help                   Show this help message

EXAMPLES:
    # Create OpenShift 4.14 VM with pull secret
    $0 -v 4.14 --pull-secret ~/pull-secret.txt

    # Create with custom VM name and key
    $0 -v 4.15 -n my-ocp-cluster -k my-ocp-key --pull-secret ~/pull-secret.txt

    # Create with custom instance types and higher spot bid
    $0 -v 4.14 -t "m5.large,c5.large" -r 20 --pull-secret ~/pull-secret.txt

SPECIFICATIONS:
    Default configuration: 8 vCPUs, 16GB RAM (Single Node OpenShift compatible)

NOTES:
    - Script automatically selects optimal AWS region/AZ based on spot pricing
    - Uses RHEL AMIs compatible with specified OCP version
    - Creates security groups and SSH keys automatically
    - Creates and associates an Elastic IP for persistent static IP address
    - VM comes pre-configured with OCP prerequisites installed
    - Spot instances save 50-90% compared to on-demand pricing
    - Pull secret can be downloaded from: https://console.redhat.com/openshift/install/pull-secret
    - Elastic IP persists even if spot instance is terminated/replaced

EOF
}

# Main function
main() {
    local ocp_version=""
    local vm_name="$DEFAULT_VM_NAME_PREFIX"
    local key_name="$DEFAULT_KEY_NAME"
    local instance_types_input=""
    local increase_rate="10"
    local volume_size="$DEFAULT_VOLUME_SIZE"
    local volume_type="$DEFAULT_VOLUME_TYPE"
    local pull_secret_file=""
    local debug=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--ocp-version)
                ocp_version="$2"
                shift 2
                ;;
            -n|--vm-name)
                vm_name="$2"
                shift 2
                ;;
            -k|--key-name)
                key_name="$2"
                shift 2
                ;;
            -t|--instance-types)
                instance_types_input="$2"
                shift 2
                ;;
            -r|--increase-rate)
                increase_rate="$2"
                shift 2
                ;;
            --volume-size)
                volume_size="$2"
                shift 2
                ;;
            --volume-type)
                volume_type="$2"
                shift 2
                ;;
            --pull-secret)
                pull_secret_file="$2"
                shift 2
                ;;
            -d|--debug)
                export DEBUG=1
                debug="-d"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Validate required parameters
    if [[ -z "$ocp_version" ]]; then
        log_error "OCP version is required. Use -v or --ocp-version"
        usage
        exit 1
    fi
    
    # Validate dependencies
    if [[ ! -f "$SPOT_ALLOCATION_SCRIPT" ]]; then
        log_error "Spot allocation script not found: $SPOT_ALLOCATION_SCRIPT"
        exit 1
    fi
    
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found. Please install AWS CLI and configure credentials."
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log_error "jq not found. Please install jq for JSON processing."
        exit 1
    fi
    
    log_info "Starting OCP VM creation process..."
    log_info "OCP Version: $ocp_version"
    log_info "VM Name: $vm_name"
    
    # Get OCP requirements
    local requirements
    requirements=$(get_ocp_requirements)
    local cpus memory
    cpus=$(echo "$requirements" | jq -r '.cpus')
    memory=$(echo "$requirements" | jq -r '.memory')
    
    log_info "Resource Requirements: ${cpus} vCPUs, ${memory}GB RAM"
    
    log_info "Using AMI pattern: $DEFAULT_AMI_PATTERN"
    
    # Build spot allocation command
    local spot_cmd="$SPOT_ALLOCATION_SCRIPT"
    spot_cmd+=" $DEFAULT_AMI_PATTERN"
    
    if [[ -n "$instance_types_input" ]]; then
        spot_cmd+=" -i \"$instance_types_input\""
    else
        spot_cmd+=" -c $cpus -m $memory"
    fi
    
    spot_cmd+=" -r $increase_rate"
    [[ -n "$debug" ]] && spot_cmd+=" $debug"
    
    log_info "Running spot allocation analysis..."
    log_debug "Command: $spot_cmd"
    
    # Get optimal spot allocation
    local spot_result
    if ! spot_result=$(eval "$spot_cmd"); then
        log_error "Failed to find optimal spot allocation"
        exit 1
    fi
    
    local region
    region=$(echo "$spot_result" | jq -r '.region')
    
    log_success "Found optimal region: $region"
    
    # Setup SSH key
    setup_ssh_key "$key_name" "$region"
    
    # Setup security group
    local security_group_id
    security_group_id=$(setup_security_group "$region" "${vm_name}-ocp-sg")
    
    # Create Elastic IP
    local eip_result
    eip_result=$(create_elastic_ip "$region" "$vm_name")
    local allocation_id public_ip
    allocation_id=$(echo "$eip_result" | jq -r '.allocation_id')
    public_ip=$(echo "$eip_result" | jq -r '.public_ip')
    
    # Generate user data script with actual values
    local pubkey username pull_secret pass_developer pass_kubeadmin public_ip
    
    # Extract public key from the private key file created by setup_ssh_key()
    pubkey=$(cat "$HOME/.ssh/${key_name}.pub")
    username="core"   
    # Load pull secret from file if provided
    local pull_secret
    if [[ -n "$pull_secret_file" ]]; then
        if [[ -f "$pull_secret_file" ]]; then
            pull_secret=$(cat "$pull_secret_file")
            log_info "Using pull secret from: $pull_secret_file"
        else
            log_error "Pull secret file not found: $pull_secret_file"
            exit 1
        fi
    else
        log_warn "No pull secret provided - OpenShift installation will require manual configuration"
        log_warn "Download pull secret from: https://console.redhat.com/openshift/install/pull-secret"
        exit 1
    fi
    pass_developer="developer123" # Default password - should be changed
    pass_kubeadmin="admin123" # Default password - should be changed
    # public_ip is already set from Elastic IP creation above
    
    log_info "Using public key from AWS key pair: $key_name"
    log_warn "Using default credentials - change passwords after deployment"
    
    local user_data
    user_data=$(generate_user_data "$pubkey" "$username" "$pull_secret" "$pass_developer" "$pass_kubeadmin" "$public_ip")
    
    # Create the VM
    local vm_result
    vm_result=$(create_ocp_vm \
        "$spot_result" \
        "$vm_name" \
        "$key_name" \
        "$security_group_id" \
        "$volume_size" \
        "$volume_type" \
        "$user_data" \
        "$allocation_id" \
        "$public_ip")
    
    echo ""
    echo "========================================"
    log_success "OCP VM Creation Completed!"
    echo "========================================"
    
    # Display final results
    echo "$vm_result" | jq -r '
        "VM Details:",
        "  Instance ID: " + .instance_id,
        "  Public IP: " + .public_ip,
        "  Region: " + .region + " (" + .availability_zone + ")",
        "  Instance Type: " + .instance_type,
        "  Spot Price: $" + (.spot_price | tostring) + "/hour",
        "",
        "Connection:",
        "  SSH Command: " + .ssh_command,
        "  Key File: " + .key_file,
        "",
        "Next Steps:",
        "  1. Wait ~2-3 minutes for VM initialization to complete",
        "  2. SSH to the VM using the command above",
        "  3. Run: /opt/ocp/prepare-install.sh",
        "  4. Download OpenShift installer and proceed with installation"
    '
}

# Run main function only if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi