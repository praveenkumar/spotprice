#!/bin/bash

# AWS Spot Instance Allocation Optimizer
# Bash implementation of AllocationDataOnSpot functionality
# Finds the best AWS region/AZ for spot instances based on pricing and placement scores

set -euo pipefail

# Configuration
readonly TOLERANCE_SCORE=3
readonly MAX_PLACEMENT_RESULTS=10
readonly PRICE_INCREASE_RATE=${SPOT_PRICE_INCREASE_RATE:-10}  # Default 10% increase
readonly PRODUCT_DESCRIPTION="Linux/UNIX"
readonly CACHE_DIR="/tmp/spot-cache"
readonly PARALLEL_JOBS=1

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

# Ensure cache directory exists
mkdir -p "$CACHE_DIR"

# Function to get all AWS regions
get_aws_regions() {
    local cache_file="$CACHE_DIR/regions.json"
    
    # Cache for 1 hour
    if [[ -f "$cache_file" && $(($(date +%s) - $(stat -c %Y "$cache_file"))) -lt 3600 ]]; then
        cat "$cache_file"
        return
    fi
    
    log_debug "Fetching AWS regions..."
    aws ec2 describe-regions --query 'Regions[].RegionName' --output json | tee "$cache_file"
}

# Function to get instance types based on requirements
get_instance_types() {
    local vcpus="$1"
    local memory_gib="$2"
    local arch="${3:-x86_64}"
    local gpu_manufacturer="${4:-}"
    
    log_debug "Finding instance types: vCPUs=$vcpus, Memory=${memory_gib}GiB, Arch=$arch"
    
    local arch_filter
    case "$arch" in
        "arm64"|"aarch64") arch_filter="arm64" ;;
        *) arch_filter="x86_64" ;;
    esac
    
    if [[ -n "$gpu_manufacturer" ]]; then
        # For GPU instances, use a broader search
        aws ec2 describe-instance-types \
            --filters "Name=processor-info.supported-architecture,Values=$arch_filter" \
                     "Name=accelerator-info.type,Values=gpu" \
            --query "InstanceTypes[?AcceleratorInfo.Accelerators[0].Manufacturer=='$gpu_manufacturer'].InstanceType" \
            --output json | jq -r '.[]' | head -5
    else
        # For CPU/Memory based selection
        aws ec2 describe-instance-types \
            --filters "Name=processor-info.supported-architecture,Values=$arch_filter" \
                     "Name=vcpu-info.default-vcpus,Values=$vcpus" \
            --query "InstanceTypes[?MemoryInfo.SizeInMiB>=\`$((memory_gib * 1024))\` && MemoryInfo.SizeInMiB<=\`$((memory_gib * 1024 + 2048))\`].InstanceType" \
            --output json | jq -r '.[]' | head -5
    fi
}

# Function to get placement scores for a region
get_placement_scores() {
    local region="$1"
    local instance_types="$2"  # JSON array string
    local capacity="${3:-1}"
    
    local cache_file="$CACHE_DIR/placement-${region}.json"
    
    # Cache for 30 minutes
    if [[ -f "$cache_file" && $(($(date +%s) - $(stat -c %Y "$cache_file"))) -lt 1800 ]]; then
        cat "$cache_file"
        return
    fi
    
    log_debug "Getting placement scores for region: $region"
    # Convert JSON array to comma-separated list
    local instance_list
    instance_list=$(echo "$instance_types" | jq -r 'join(" ")')
    
    local result
    result=$(aws ec2 get-spot-placement-scores \
        --region "$region" \
        --single-availability-zone \
        --instance-types $instance_list \
        --region-names "$region" \
        --target-capacity "$capacity" \
        --max-results "$MAX_PLACEMENT_RESULTS" \
        --output json)
    
    # Get AZ ID to AZ name mapping for this region
    local az_mapping
    az_mapping=$(aws ec2 describe-availability-zones \
        --region "$region" \
        --query 'AvailabilityZones[].{ZoneId: ZoneId, ZoneName: ZoneName}' \
        --output json)
    
    # Filter scores >= tolerance and add actual AZ names
    echo "$result" | jq --argjson tolerance "$TOLERANCE_SCORE" --argjson az_mapping "$az_mapping" '
        .SpotPlacementScores 
        | map(select(.Score > $tolerance))  
        | map(. as $s | $az_mapping[] | select(.ZoneId == $s.AvailabilityZoneId) | ($s + {AZName: .ZoneName}))

    ' | tee "$cache_file"
}

# Function to get spot pricing history for a region
get_spot_pricing() {
    local region="$1"
    local instance_types="$2"  # JSON array string
    local product_description="${3:-Linux/UNIX}"
    
    log_debug "Getting spot pricing for region: $region"
    
    # Convert JSON array to space-separated list for AWS CLI
    local instance_list
    instance_list=$(echo "$instance_types" | jq -r '.[]' | tr '\n' ' ')
    
    local start_time end_time
    start_time=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S)
    end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
    
    aws ec2 describe-spot-price-history \
        --region "$region" \
        --instance-types $instance_list \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --filters "Name=product-description,Values=$product_description" \
        --output json 2>/dev/null || echo '{"SpotPriceHistory": []}'
}

# Function to process spot pricing data and calculate averages
process_spot_pricing() {
    local region="$1"
    local pricing_data="$2"
    
    log_debug "Processing spot pricing data for region: $region"
    
    echo "$pricing_data" | jq --arg region "$region" '
        .SpotPriceHistory 
        | group_by("\(.AvailabilityZone)-\(.InstanceType)")
        | map({
            Region: $region,
            AvailabilityZone: .[0].AvailabilityZone,
            InstanceType: .[0].InstanceType,
            Prices: [.[] | .SpotPrice | tonumber],
            Count: length
        })
        | map(. + {
            AVGPrice: (.Prices | add / length),
            MaxPrice: (.Prices | max),
            MinPrice: (.Prices | min)
        })
        | map(select(.Count > 0))
    '
}



# Function to check AMI availability globally across all regions
check_global_ami_availability() {
    local ami_name="$1"
    local ami_arch="${2:-x86_64}"
    
    if [[ -z "$ami_name" ]]; then
        log_info "No AMI name provided, AMI name is required"
        exit 1
    fi
    
    log_info "Checking global AMI availability for: $ami_name ($ami_arch)"
    
    # Get all regions
    local regions
    regions=$(get_aws_regions)
    
    # Create temporary directory for parallel checks
    local check_dir="$CACHE_DIR/ami-check-$$"
    mkdir -p "$check_dir"
    
    # Check all regions in parallel
    echo "$regions" | jq -r '.[]' | xargs -I {} -P 10 bash -c "
        if aws ec2 describe-images \
            --region '{}' \
            --filters 'Name=name,Values=$ami_name' \
                     'Name=architecture,Values=$ami_arch' \
                     'Name=state,Values=available' \
            --query 'length(Images)' \
            --output text 2>/dev/null | grep -q '^[1-9]'; then
            echo '{}' > '$check_dir/found-{}'
        fi
    "
    
    # Check if any region has the AMI
    local found_regions
    found_regions=$(find "$check_dir" -name "found-*" | wc -l)
    
    # Clean up
    rm -rf "$check_dir"
    
    if [[ "$found_regions" -eq 0 ]]; then
        log_error "AMI '$ami_name' ($ami_arch) is not available in any AWS region"
        log_error "Please check the AMI name pattern and try again"
        exit 1
    else
        log_success "AMI '$ami_name' found in $found_regions region(s)"
    fi
}

# Function to filter instance types available in a region
filter_instance_types_by_region() {
    local region="$1"
    local instance_types="$2"  # JSON array string
    
    log_debug "Filtering instance types available in region: $region"
    
    local available_types
    available_types=$(echo "$instance_types" | jq -r '.[]' | xargs -I {} aws ec2 describe-instance-type-offerings \
        --region "$region" \
        --location-type "region" \
        --filters "Name=location,Values=$region" "Name=instance-type,Values={}" \
        --query 'InstanceTypeOfferings[].InstanceType' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "$available_types" ]]; then
        echo "$available_types" | tr '\t' '\n' | jq -R . | jq -s .
    else
        echo "[]"
    fi
}

# Function to calculate safe spot bid price
calculate_safe_spot_bid() {
    local base_price="$1"
    local increase_rate="${2:-$PRICE_INCREASE_RATE}"
    
    echo "$base_price" | awk -v rate="$increase_rate" '{
        if (rate > 0) {
            print $1 * (1 + rate/100)
        } else {
            print $1
        }
    }'
}

# Function to process a single region (for parallel execution)
process_region() {
    local region="$1"
    local instance_types="$2"
    local ami_name="${3:-}"
    local ami_arch="${4:-x86_64}"
    local product_description="${5:-Linux/UNIX}"
    
    local result_file="$CACHE_DIR/result-$region.json"
    
    log_debug "Processing region: $region"
    
    # Get placement scores
    local placement_scores
    placement_scores=$(get_placement_scores "$region" "$instance_types")
    
    # Skip region if no good placement scores
    local placement_count
    placement_count=$(echo "$placement_scores" | jq 'length')
    if [[ "$placement_count" -eq 0 ]]; then
        log_debug "No suitable placement scores for region: $region"
        echo '[]' > "$result_file"
        return
    fi
    
    # Get spot pricing
    local spot_pricing_raw
    spot_pricing_raw=$(get_spot_pricing "$region" "$instance_types" "$product_description")
    
    # Process pricing data
    local spot_pricing
    spot_pricing=$(process_spot_pricing "$region" "$spot_pricing_raw")
    
    # Cross-reference placement scores with pricing data
    # this ensures you only get options that have 
    # both good pricing data AND good reliability scores, so you don't 
    # end up with a cheap instance that gets terminated frequently.
    local final_result
    final_result=$(echo "$placement_scores $spot_pricing" | jq -s --argjson ami_available "true" '
        .[0] as $placement | .[1] as $pricing |
        if $ami_available then
            [
                $pricing[] as $price |
                $placement[] as $place |
                if $place.AZName == $price.AvailabilityZone then
                    {
                        Region: $price.Region,
                        AvailabilityZone: $price.AvailabilityZone,
                        InstanceType: $price.InstanceType,
                        AVGPrice: $price.AVGPrice,
                        MaxPrice: $price.MaxPrice,
                        Score: $place.Score
                    }
                else empty end
            ]
        else []
        end
    ')
    
    echo "$final_result" > "$result_file"
    log_debug "Completed processing region: $region"
}

# Main function to find optimal spot allocation
find_optimal_spot_allocation() {
    local instance_types="$1"  # JSON array
    local ami_name="${2:-}"
    local ami_arch="${3:-x86_64}"
    local product_description="${4:-Linux/UNIX}"
    local increase_rate="${5:-$PRICE_INCREASE_RATE}"
    
    log_info "Starting global spot instance optimization..."
    log_info "Instance types: $(echo "$instance_types" | jq -c .)"
    [[ -n "$ami_name" ]] && log_info "AMI filter: $ami_name ($ami_arch)"
    
    # Get all AWS regions
    local regions
    regions=$(get_aws_regions)
    local region_count
    region_count=$(echo "$regions" | jq 'length')
    
    log_info "Analyzing $region_count regions for optimal spot allocation..."
    
    # Clean up previous results
    rm -f "$CACHE_DIR"/result-*.json
    
    # Process regions in parallel
    echo "$regions" | jq -r '.[]' | xargs -I {} -P "$PARALLEL_JOBS" bash -c "
        source '$0'
        process_region '{}' '$instance_types' '$ami_name' '$ami_arch' '$product_description'
    "
    
    # Collect and merge results
    log_info "Getting all results ..."
    local all_results="[]"
    for result_file in "$CACHE_DIR"/result-*.json; do
        if [[ -f "$result_file" ]]; then
            local region_result
            region_result=$(cat "$result_file")
            all_results=$(echo "$all_results $region_result" | jq -s 'add')
        fi
    done
    
    # Find the best option (lowest max price)
    local best_option
    log_info "Getting best option ..."
    best_option=$(echo "$all_results" | jq 'sort_by(.MaxPrice) | .[0] // empty')
    
    if [[ "$best_option" == "null" || "$best_option" == "" ]]; then
        log_error "No suitable spot options found across all regions"
        return 1
    fi
    
    # Extract details
    local region az instance_type avg_price max_price score
    region=$(echo "$best_option" | jq -r '.Region')
    az=$(echo "$best_option" | jq -r '.AvailabilityZone')
    instance_type=$(echo "$best_option" | jq -r '.InstanceType')
    avg_price=$(echo "$best_option" | jq -r '.AVGPrice')
    max_price=$(echo "$best_option" | jq -r '.MaxPrice')
    score=$(echo "$best_option" | jq -r '.Score')
    
    log_success "Found optimal spot allocation:"
    log_info "  Region: $region"
    log_info "  Availability Zone: $az"
    log_info "  Instance Type: $instance_type"
    log_info "  Average Price: \$$(printf '%.4f' "$avg_price")/hour"
    log_info "  Max Price: \$$(printf '%.4f' "$max_price")/hour"
    log_info "  Placement Score: $score/10"
    
    # Calculate safe bid price
    local safe_bid
    safe_bid=$(calculate_safe_spot_bid "$max_price" "$increase_rate")
    log_info "  Recommended Bid: \$$(printf '%.4f' "$safe_bid")/hour (+${increase_rate}%)"
    
    # Filter instance types available in selected region
    local available_instance_types
    available_instance_types=$(filter_instance_types_by_region "$region" "$instance_types")
    
    # Output structured result
    jq -n \
        --arg region "$region" \
        --arg az "$az" \
        --argjson spot_price "$safe_bid" \
        --argjson instance_types "$available_instance_types" \
        --argjson avg_price "$avg_price" \
        --argjson max_price "$max_price" \
        --argjson score "$score" \
        --arg primary_instance_type "$instance_type" \
        '{
            region: $region,
            availability_zone: $az,
            spot_price: $spot_price,
            instance_types: $instance_types,
            primary_instance_type: $primary_instance_type,
            pricing: {
                avg_price: $avg_price,
                max_price: $max_price,
                safe_bid: $spot_price
            },
            placement_score: $score
        }'
}

# Function to display usage information
usage() {
    cat << EOF
AWS Spot Instance Allocation Optimizer

Usage: $0 [AMI_NAME] [OPTIONS]

POSITIONAL ARGUMENTS:
    AMI_NAME                     AMI name pattern to validate availability (optional)

OPTIONS:
    -c, --cpus CPUS              Number of vCPUs required
    -m, --memory MEMORY          Memory in GiB required  
    -a, --arch ARCH              Architecture (x86_64|arm64|aarch64)
    -g, --gpu GPU                GPU manufacturer (nvidia|amd)
    -i, --instance-types TYPES   Comma-separated list of instance types
    -r, --increase-rate RATE     Spot price increase rate percentage (default: 10)
    -p, --product PRODUCT        Product description (default: Linux/UNIX)
    -d, --debug                  Enable debug output
    -h, --help                   Show this help message

EXAMPLES:
    # Find optimal spot for 4 vCPUs, 16GB RAM
    $0 "amzn2-ami-hvm-*" -c 4 -m 16
    
    # Find optimal spot for specific instance types
    $0 "amzn2-ami-hvm-*" -i "m5.large,m5.xlarge,m4.large"
    
    # Find optimal spot with AMI validation
    $0 "amzn2-ami-hvm-*" -c 2 -m 8 -a x86_64
    
    # Find optimal GPU instance with AMI validation
    $0 "ubuntu/images/hvm-ssd/ubuntu-*" -g nvidia -c 4 -m 16
    

ENVIRONMENT VARIABLES:
    SPOT_PRICE_INCREASE_RATE    Default spot price increase rate (default: 10)
    DEBUG                       Enable debug output (set to 1)
    AWS_PROFILE                 AWS profile to use
    AWS_REGION                  Default AWS region

EOF
}

# Main script logic
main() {
    local cpus=""
    local memory=""
    local arch="x86_64"
    local gpu=""
    local instance_types_input=""
    local ami_name=""
    local increase_rate="$PRICE_INCREASE_RATE"
    local product_description="$PRODUCT_DESCRIPTION"
    
    # Handle positional AMI name argument first
    if [[ $# -gt 0 && "$1" != -* ]]; then
        ami_name="$1"
        shift
        log_info "AMI name set to: $ami_name"
    fi
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--cpus)
                cpus="$2"
                shift 2
                ;;
            -m|--memory)
                memory="$2" 
                shift 2
                ;;
            -a|--arch)
                arch="$2"
                shift 2
                ;;
            -g|--gpu)
                gpu="$2"
                shift 2
                ;;
            -i|--instance-types)
                instance_types_input="$2"
                shift 2
                ;;
            -r|--increase-rate)
                increase_rate="$2"
                shift 2
                ;;
            -p|--product)
                product_description="$2"
                shift 2
                ;;
            -d|--debug)
                export DEBUG=1
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
    
    # Validate AWS CLI availability
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found. Please install AWS CLI and configure credentials."
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log_error "jq not found. Please install jq for JSON processing."
        exit 1
    fi
    
    # Check AMI availability globally before processing regions
    check_global_ami_availability "$ami_name" "$arch"
    # Determine instance types
    local instance_types
    if [[ -n "$instance_types_input" ]]; then
        # Convert comma-separated list to JSON array
        instance_types=$(echo "$instance_types_input" | tr ',' '\n' | jq -R . | jq -s .)
        log_info "Using provided instance types: $(echo "$instance_types" | jq -c .)"
    elif [[ -n "$cpus" && -n "$memory" ]]; then
        # Auto-select instance types based on requirements
        log_info "Auto-selecting instance types for: ${cpus} vCPUs, ${memory}GiB RAM, ${arch} architecture"
        local types_list
        types_list=$(get_instance_types "$cpus" "$memory" "$arch" "$gpu")
        if [[ -z "$types_list" ]]; then
            log_error "No instance types found matching the requirements"
            exit 1
        fi
        instance_types=$(echo "$types_list" | jq -R . | jq -s . | jq 'map(select(length > 0))')
        log_info "Selected instance types: $(echo "$instance_types" | jq -c .)"
    else
        log_error "Either specify instance types (-i) or provide CPU/memory requirements (-c, -m)"
        usage
        exit 1
    fi
    
    # Validate instance types array is not empty
    local type_count
    type_count=$(echo "$instance_types" | jq 'length')
    if [[ "$type_count" -eq 0 ]]; then
        log_error "No valid instance types to analyze"
        exit 1
    fi
    
    # Note: Child processes will use the readonly PRICE_INCREASE_RATE from global scope
    
    # Run the optimization with custom increase rate
    find_optimal_spot_allocation "$instance_types" "$ami_name" "$arch" "$product_description" "$increase_rate"
}

# Run main function only if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

