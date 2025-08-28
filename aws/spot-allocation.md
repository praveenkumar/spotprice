# AWS Spot Instance Allocation Optimizer - Bash Implementation

This is a bash implementation of the `AllocationDataOnSpot` functionality from the [mapt](https://github.com/redhat-developer/mapt) Go codebase. It provides intelligent, globally-optimized spot instance allocation that balances cost, availability, and reliability.

## Overview

The bash implementation mirrors the sophisticated Go logic by:

1. **Global Analysis**: Searches across all AWS regions simultaneously
2. **Global AMI Validation**: Checks AMI availability across all regions upfront with parallel processing
3. **Intelligent Selection**: Cross-references placement scores, spot pricing, and AMI availability
4. **Parallel Processing**: Uses bash background jobs to process multiple regions concurrently
5. **Smart Caching**: Caches API results to reduce redundant calls and improve performance
6. **Safe Bidding**: Applies configurable price buffers to reduce spot termination risk

## Architecture Mapping

### Go Implementation → Bash Implementation

| Go Component | Bash Equivalent | Description |
|--------------|-----------------|-------------|
| `SpotOptionRequest.Create()` | `find_optimal_spot_allocation()` | Main orchestration function |
| `runByRegion()` | `xargs -P` parallel processing | Concurrent region processing |
| `placementScoresAsync()` | `get_placement_scores()` | AWS placement score retrieval |
| `spotPricingAsync()` | `get_spot_pricing()` + `process_spot_pricing()` | Spot price analysis |
| `selectSpotChoice()` | JSON cross-referencing with `jq` | Data correlation and selection |
| `FilterInstaceTypesOfferedByRegion()` | `filter_instance_types_by_region()` | Region-specific instance filtering |
| `spotPriceBid()` | `calculate_safe_spot_bid()` | Safe price calculation |


## Usage

### Prerequisites

```bash
# Install required tools
sudo apt-get install -y awscli jq bc

# Configure AWS credentials
aws configure
```

### Basic Usage

```bash
# Make script executable
chmod +x spot-allocation.sh

# Find optimal spot with AMI validation (recommended)
./spot-allocation.sh "amzn2-ami-hvm-*" -c 4 -m 16

# Use specific instance types with AMI validation
./spot-allocation.sh "amzn2-ami-hvm-*" -i "m5.large,m5.xlarge,c5.large"

# ARM64 instances with Ubuntu AMI
./spot-allocation.sh "ubuntu/images/hvm-ssd/ubuntu-*" -c 4 -m 16 -a arm64

# GPU instances with specific AMI
./spot-allocation.sh "ubuntu/images/hvm-ssd/ubuntu-*" -g nvidia -c 4 -m 16

# Different AMI architectures
./spot-allocation.sh "amzn2-ami-hvm-*-x86_64-gp2" -c 2 -m 8 -a x86_64
```

### Command Line Options

**Positional Arguments:**
| Argument | Description | Example |
|----------|-------------|---------|  
| `AMI_NAME` | AMI name pattern (required) | `"amzn2-ami-hvm-*"` |

**Options:**
| Option | Description | Example |
|--------|-------------|---------|  
| `-c, --cpus` | Number of vCPUs | `-c 4` |
| `-m, --memory` | Memory in GiB | `-m 16` |
| `-a, --arch` | Architecture | `-a arm64` |
| `-g, --gpu` | GPU manufacturer | `-g nvidia` |
| `-i, --instance-types` | Specific instance types | `-i "m5.large,c5.large"` |
| `-r, --increase-rate` | Spot price buffer % | `-r 15` |
| `-p, --product` | Product description | `-p "Linux/UNIX"` |
| `-d, --debug` | Enable debug output | `-d` |
| `-h, --help` | Show help | `-h` |

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `SPOT_PRICE_INCREASE_RATE` | Default price increase rate | `10` |
| `DEBUG` | Enable debug output | `0` |
| `AWS_PROFILE` | AWS profile to use | (default) |
| `AWS_REGION` | Default AWS region | (auto-detected) |

## Output Format

The script outputs JSON with the following structure:

```json
{
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
}
```

## Implementation Details

### 1. Global AMI Availability Check

```bash
# Check AMI availability across all regions upfront
check_global_ami_availability() {
    local ami_name="$1"
    local ami_arch="${2:-x86_64}"
    
    # Get all regions and check in parallel
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
}
```

### 2. Region Discovery & Parallel Processing

```bash
# Get all AWS regions
regions=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output json)

# Process regions in parallel (up to 1 concurrent job by default)
echo "$regions" | jq -r '.[]' | xargs -I {} -P "$PARALLEL_JOBS" bash -c "process_region '{}' ..."
```

### 3. Placement Score Analysis

```bash
aws ec2 get-spot-placement-scores \
    --region "$region" \
    --single-availability-zone \
    --instance-types "$instance_list" \
    --target-capacity 1 \
    --max-results 10
```

- Filters scores >= tolerance threshold (default: 3)
- Maps availability zone IDs to names
- Sorts by score (highest first)

### 4. Spot Pricing Analysis  

```bash
# Get last hour's pricing data
start_time=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S)
end_time=$(date -u +%Y-%m-%dT%H:%M:%S)

aws ec2 describe-spot-price-history \
    --region "$region" \
    --start-time "$start_time" \
    --end-time "$end_time" \
    --filters "Name=product-description,Values=Linux/UNIX"
```

- Groups by AZ + instance type
- Calculates average, min, max prices
- Handles pricing data aggregation with `jq`

### 5. Data Cross-Referencing

```bash
# Cross-reference placement scores with pricing data
jq -s --argjson ami_available "$ami_available" '
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
'
```

### 6. Optimal Selection

- Collects results from all regions
- Sorts by maximum price (ascending)
- Selects lowest-cost option that meets placement score requirements
- Applies safety margin to bid price

### 7. Caching Strategy

```bash
cache_file="$CACHE_DIR/placement-${region}.json"

# Cache for 30 minutes
if [[ -f "$cache_file" && $(($(date +%s) - $(stat -c %Y "$cache_file"))) -lt 1800 ]]; then
    cat "$cache_file"
    return
fi
```

- Regions list: 1 hour cache
- Placement scores: 30 minutes cache  
- Instance types: No cache (dynamic)
- Results are written per-region for debugging

## Performance Characteristics

### Parallel Processing

- **Concurrency**: Up to 10 regions processed simultaneously
- **Typical Runtime**: 30-60 seconds for global analysis
- **API Calls**: ~50-100 total (cached where possible)

### Error Handling

- Graceful degradation when regions are unavailable
- Skip regions with no suitable placement scores
- Robust JSON parsing with error recovery
- Detailed error logging and debugging

### Resource Usage

- **Memory**: Minimal (mainly JSON caching)
- **Disk**: ~1-5MB for temporary cache files
- **Network**: Optimized with intelligent caching

## Testing

Run the test suite to verify functionality:

```bash
# Run unit tests
chmod +x test-spot-functions.sh
./test-spot-functions.sh

# Run integration examples
chmod +x example-spot-usage.sh  
./example-spot-usage.sh
```

## Integration with Existing Codebase

The bash implementation can be integrated into the existing Go codebase as:

1. **Standalone Tool**: For manual analysis and verification
2. **Fallback Option**: When Go dependencies aren't available
3. **CI/CD Integration**: Direct use in deployment pipelines
4. **Development Tool**: Quick spot analysis during development


## Troubleshooting

### Common Issues

1. **AWS CLI Not Configured**
   ```bash
   aws configure
   # or
   export AWS_PROFILE=myprofile
   ```

2. **Missing Dependencies**
   ```bash
   # Ubuntu/Debian
   sudo apt-get install -y awscli jq bc
   
   # MacOS
   brew install awscli jq
   ```

3. **Permission Errors**
   ```bash
   chmod +x spot-allocation.sh
   ```

4. **AMI Not Found Error**
   ```
   [ERROR] AMI 'amzn2-ami-hvm-*' (x86_64) is not available in any AWS region
   ```
   - Check AMI name pattern: `aws ec2 describe-images --owners amazon --filters "Name=name,Values=amzn2-ami-hvm-*"`
   - Verify architecture matches: use `-a arm64` for ARM instances
   - Try broader patterns: `"amzn2-ami-*"` instead of `"amzn2-ami-hvm-*"`

5. **No Results Found**
   - Check if instance types exist: `aws ec2 describe-instance-types`
   - Verify AMI name patterns work globally
   - Enable debug mode: `-d` flag

### Debug Mode

Enable detailed debugging:

```bash
export DEBUG=1
./spot-allocation.sh "amzn2-ami-hvm-*" -d -c 4 -m 16
```
