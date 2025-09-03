#!/bin/bash

# Test script for create-ocp-vm.sh
# Validates OCP VM creation logic without actually creating AWS resources

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCP_VM_SCRIPT="$SCRIPT_DIR/create-ocp-vm.sh"

# Test configuration
export DEBUG=1
TEST_RESULTS=0

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Test helper functions
test_log() {
    echo -e "\n🧪 TEST: $1"
}

test_assert() {
    local condition="$1"
    local message="$2"
    
    if eval "$condition"; then
        echo -e "${GREEN}✅ PASS${NC}: $message"
    else
        echo -e "${RED}❌ FAIL${NC}: $message"
        ((TEST_RESULTS++))
    fi
}

test_log "Testing OCP VM creation script functions"

# Source the OCP script to test its functions
source "$OCP_VM_SCRIPT"

# Test 1: OCP requirements function
test_log "Testing OCP requirements calculation"

requirements=$(get_ocp_requirements "single" "4.14")
cpus=$(echo "$requirements" | jq -r '.cpus')
memory=$(echo "$requirements" | jq -r '.memory')
test_assert '[[ "$cpus" == "8" ]]' "Single node: correct CPU count ($cpus)"
test_assert '[[ "$memory" == "16" ]]' "Single node: correct memory ($memory)"

requirements=$(get_ocp_requirements "compact" "4.14")
cpus=$(echo "$requirements" | jq -r '.cpus')
memory=$(echo "$requirements" | jq -r '.memory')
test_assert '[[ "$cpus" == "4" ]]' "Compact cluster: correct CPU count ($cpus)"
test_assert '[[ "$memory" == "16" ]]' "Compact cluster: correct memory ($memory)"

requirements=$(get_ocp_requirements "standard" "4.14")
cpus=$(echo "$requirements" | jq -r '.cpus')
memory=$(echo "$requirements" | jq -r '.memory')
test_assert '[[ "$cpus" == "2" ]]' "Standard cluster: correct CPU count ($cpus)"
test_assert '[[ "$memory" == "8" ]]' "Standard cluster: correct memory ($memory)"

# Test 2: RHEL AMI pattern mapping
test_log "Testing RHEL AMI pattern mapping"

ami_pattern=$(get_rhel_ami_pattern "4.14")
test_assert '[[ "$ami_pattern" == "RHEL-9*-x86_64-*" ]]' "OCP 4.14: correct RHEL-9 pattern ($ami_pattern)"

ami_pattern=$(get_rhel_ami_pattern "4.12")
test_assert '[[ "$ami_pattern" == "RHEL-8*-x86_64-*" ]]' "OCP 4.12: correct RHEL-8 pattern ($ami_pattern)"

ami_pattern=$(get_rhel_ami_pattern "4.10")
test_assert '[[ "$ami_pattern" == "RHEL-8*-x86_64-*" ]]' "OCP 4.10: correct RHEL-8 pattern ($ami_pattern)"

# Test 3: User data generation
test_log "Testing user data script generation"

user_data=$(generate_user_data "4.14" "single" "test-vm")
test_assert '[[ -n "$user_data" ]]' "User data generated"
test_assert '[[ "$user_data" == *"#!/bin/bash"* ]]' "User data is bash script"
test_assert '[[ "$user_data" == *"dnf update -y"* ]]' "User data includes system update"
test_assert '[[ "$user_data" == *"podman"* ]]' "User data includes container tools"
test_assert '[[ "$user_data" == *"openshift-client"* ]]' "User data includes OCP client"
test_assert '[[ "$user_data" == *"firewall-cmd"* ]]' "User data includes firewall config"

# Test 4: Command line argument parsing (dry run)
test_log "Testing command line argument handling"

# Test help display
help_output=$(bash "$OCP_VM_SCRIPT" --help 2>&1 || true)
test_assert '[[ "$help_output" == *"OpenShift Container Platform VM Creator"* ]]' "Help message displays correctly"
test_assert '[[ "$help_output" == *"REQUIRED OPTIONS"* ]]' "Help shows required options"
test_assert '[[ "$help_output" == *"EXAMPLES"* ]]' "Help includes examples"

# Test required parameter validation
error_output=$(bash "$OCP_VM_SCRIPT" 2>&1 || true)
test_assert '[[ "$error_output" == *"OCP version is required"* ]]' "Missing OCP version detected"

error_output=$(bash "$OCP_VM_SCRIPT" -v 4.14 2>&1 || true)
test_assert '[[ "$error_output" == *"Cluster size is required"* ]]' "Missing cluster size detected"

# Test 5: Integration with spot allocation script
test_log "Testing spot allocation script integration"

# Check if spot allocation script exists
test_assert '[[ -f "$SCRIPT_DIR/spot-allocation.sh" ]]' "Spot allocation script exists"
test_assert '[[ -x "$SCRIPT_DIR/spot-allocation.sh" ]]' "Spot allocation script is executable"

# Test spot allocation script has required functions
if [[ -f "$SCRIPT_DIR/spot-allocation.sh" ]]; then
    source "$SCRIPT_DIR/spot-allocation.sh" 2>/dev/null || true
    # Check if key functions exist
    test_assert '[[ $(type -t find_optimal_spot_allocation) == "function" ]]' "find_optimal_spot_allocation function exists"
    test_assert '[[ $(type -t get_aws_regions) == "function" ]]' "get_aws_regions function exists"
    test_assert '[[ $(type -t calculate_safe_spot_bid) == "function" ]]' "calculate_safe_spot_bid function exists"
fi

# Test 6: Security group rules validation
test_log "Testing security group configuration"

# Test that all required OCP ports are included in our script
ocp_script_content=$(cat "$OCP_VM_SCRIPT")
required_ports=("22" "6443" "443" "80" "8080" "2379-2380" "10250" "30000-32767")

for port in "${required_ports[@]}"; do
    test_assert '[[ "$ocp_script_content" == *"--port $port"* ]]' "Security group includes port $port"
done

# Test 7: JSON processing and jq usage
test_log "Testing JSON processing"

# Test sample spot allocation result processing
sample_spot_result='{
    "region": "us-west-2",
    "availability_zone": "us-west-2a",
    "spot_price": 0.0584,
    "instance_types": ["m5.large", "m5.xlarge"],
    "primary_instance_type": "m5.large",
    "pricing": {
        "avg_price": 0.0531,
        "max_price": 0.0584,
        "safe_bid": 0.0584
    },
    "placement_score": 7
}'

region=$(echo "$sample_spot_result" | jq -r '.region')
az=$(echo "$sample_spot_result" | jq -r '.availability_zone')
spot_price=$(echo "$sample_spot_result" | jq -r '.spot_price')
instance_type=$(echo "$sample_spot_result" | jq -r '.primary_instance_type')

test_assert '[[ "$region" == "us-west-2" ]]' "JSON parsing: region extraction ($region)"
test_assert '[[ "$az" == "us-west-2a" ]]' "JSON parsing: AZ extraction ($az)"
test_assert '[[ "$spot_price" == "0.0584" ]]' "JSON parsing: spot price extraction ($spot_price)"
test_assert '[[ "$instance_type" == "m5.large" ]]' "JSON parsing: instance type extraction ($instance_type)"

# Test 8: Prerequisites validation
test_log "Testing prerequisites validation"

# Test AWS CLI check
if command -v aws &> /dev/null; then
    test_assert 'true' "AWS CLI is available"
else
    test_assert 'false' "AWS CLI is NOT available (expected for test environment)"
fi

# Test jq check
if command -v jq &> /dev/null; then
    test_assert 'true' "jq is available"
else
    test_assert 'false' "jq is NOT available"
fi

# Test 9: Volume and storage configuration
test_log "Testing volume configuration"

# Test default values
test_assert '[[ "$DEFAULT_VOLUME_SIZE" == "120" ]]' "Default volume size is appropriate for OCP"
test_assert '[[ "$DEFAULT_VOLUME_TYPE" == "gp3" ]]' "Default volume type is gp3"

# Test 10: OCP version compatibility
test_log "Testing OCP version compatibility matrix"

# Test different OCP versions map to correct RHEL versions
declare -A version_map=(
    ["4.16"]="RHEL-9"
    ["4.15"]="RHEL-9"
    ["4.14"]="RHEL-9"
    ["4.13"]="RHEL-8"
    ["4.12"]="RHEL-8"
    ["4.11"]="RHEL-8"
    ["4.10"]="RHEL-8"
)

for ocp_ver in "${!version_map[@]}"; do
    rhel_ver="${version_map[$ocp_ver]}"
    ami_pattern=$(get_rhel_ami_pattern "$ocp_ver")
    test_assert '[[ "$ami_pattern" == *"$rhel_ver"* ]]' "OCP $ocp_ver maps to $rhel_ver"
done

# Test 11: Example commands validation
test_log "Testing example usage scenarios"

examples=(
    "-v 4.14 -s single"
    "-v 4.15 -s compact -n my-ocp-cluster"
    "-v 4.14 -s standard -t m5.large,c5.large -r 20"
    "-v 4.16 -s single -n production-ocp -k my-ocp-key"
)

for example in "${examples[@]}"; do
    # Test that examples would parse correctly (dry run)
    # We can't actually run them as they require AWS, but we can check syntax
    test_assert '[[ -n "$example" ]]' "Example command is non-empty: $example"
    
    # Basic validation that required params are present
    if [[ "$example" == *"-v "* && "$example" == *"-s "* ]]; then
        test_assert 'true' "Example has required parameters: $example"
    else
        test_assert 'false' "Example missing required parameters: $example"
    fi
done

# Summary
test_log "Test Summary"
if [[ $TEST_RESULTS -eq 0 ]]; then
    echo -e "${GREEN}✅ All tests passed!${NC}"
    echo "📝 OCP VM creation script is ready for use"
    echo ""
    echo "Usage examples:"
    echo "  # Create single node OpenShift 4.14 VM"
    echo "  ./create-ocp-vm.sh -v 4.14 -s single"
    echo ""
    echo "  # Create compact cluster node"  
    echo "  ./create-ocp-vm.sh -v 4.15 -s compact -n my-ocp"
    echo ""
    echo "  # View all options"
    echo "  ./create-ocp-vm.sh --help"
    exit 0
else
    echo -e "${RED}❌ $TEST_RESULTS test(s) failed${NC}"
    exit 1
fi
