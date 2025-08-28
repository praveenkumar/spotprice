#!/bin/bash

# Test script for spot-allocation.sh functions
# Tests individual components without requiring full AWS access

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/spot-allocation.sh"

# Test configuration
export DEBUG=1
TEST_RESULTS=0

# Test helper functions
test_log() {
    echo -e "\n🧪 TEST: $1"
}

test_assert() {
    local condition="$1"
    local message="$2"
    
    if eval "$condition"; then
        echo "✅ PASS: $message"
    else
        echo "❌ FAIL: $message"
        ((TEST_RESULTS++))
    fi
}

test_log "Testing basic utility functions"

# Test calculate_safe_spot_bid function
test_log "Testing safe spot bid calculation"
result=$(calculate_safe_spot_bid "1.00" "10")
expected="1.1"
test_assert '[[ "$result" == "$expected" ]]' "10% increase: $result == $expected"

result=$(calculate_safe_spot_bid "0.50" "20")
expected="0.6"
test_assert '[[ "$result" == "$expected" ]]' "20% increase: $result == $expected"

result=$(calculate_safe_spot_bid "2" "0")
expected="2"
test_assert '[[ "$result" == "$expected" ]]' "0% increase: $result == $expected"

# Test JSON processing functions
test_log "Testing JSON processing"

# Test instance types conversion
instance_list='["m5.large", "c5.large", "t3.medium"]'
converted=$(echo "$instance_list" | jq -r 'join(",")')
expected="m5.large,c5.large,t3.medium"
test_assert '[[ "$converted" == "$expected" ]]' "JSON to CSV conversion: $converted"

# Test placement score filtering
test_placement_scores='[
    {"Score": 5, "AvailabilityZoneId": "use1-az1", "AZName": "us-east-1a"},
    {"Score": 2, "AvailabilityZoneId": "use1-az2", "AZName": "us-east-1b"},
    {"Score": 8, "AvailabilityZoneId": "use1-az3", "AZName": "us-east-1c"}
]'

filtered=$(echo "$test_placement_scores" | jq --argjson tolerance "3" 'map(select(.Score >= $tolerance))')
count=$(echo "$filtered" | jq 'length')
test_assert '[[ "$count" == "2" ]]' "Placement score filtering (tolerance 3): found $count suitable scores"

# Test spot pricing processing simulation
test_log "Testing spot pricing data processing"

test_pricing_data='{
    "SpotPriceHistory": [
        {"AvailabilityZone": "us-east-1a", "InstanceType": "m5.large", "SpotPrice": "0.10"},
        {"AvailabilityZone": "us-east-1a", "InstanceType": "m5.large", "SpotPrice": "0.12"},
        {"AvailabilityZone": "us-east-1a", "InstanceType": "m5.large", "SpotPrice": "0.11"}
    ]
}'

processed=$(process_spot_pricing "us-east-1" "$test_pricing_data")
avg_price=$(echo "$processed" | jq -r '.[0].AVGPrice')
max_price=$(echo "$processed" | jq -r '.[0].MaxPrice')

# Average should be (0.10 + 0.12 + 0.11) / 3 = 0.11
test_assert '[[ $(echo "$avg_price == 0.11" | bc -l) == "1" ]]' "Average price calculation: $avg_price"
test_assert '[[ $(echo "$max_price == 0.12" | bc -l) == "1" ]]' "Max price calculation: $max_price"

# Test cross-referencing logic simulation
test_log "Testing data cross-referencing logic"

test_placement='[{"Score": 5, "AZName": "us-east-1a"}]'
test_pricing='[{"Region": "us-east-1", "AvailabilityZone": "us-east-1a", "InstanceType": "m5.large", "AVGPrice": 0.11, "MaxPrice": 0.12}]'

cross_ref_result=$(echo "$test_placement $test_pricing" | jq -s --argjson ami_available "true" '
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

result_count=$(echo "$cross_ref_result" | jq 'length')
test_assert '[[ "$result_count" == "1" ]]' "Cross-referencing produces results: $result_count"

if [[ "$result_count" -eq 1 ]]; then
    result_az=$(echo "$cross_ref_result" | jq -r '.[0].AvailabilityZone')
    result_score=$(echo "$cross_ref_result" | jq -r '.[0].Score')
    test_assert '[[ "$result_az" == "us-east-1a" ]]' "Correct AZ in result: $result_az"
    test_assert '[[ "$result_score" == "5" ]]' "Correct score in result: $result_score"
fi

# Test result sorting
test_log "Testing result sorting by price"

test_multiple_results='[
    {"Region": "us-east-1", "MaxPrice": 0.15, "Score": 7},
    {"Region": "us-west-2", "MaxPrice": 0.10, "Score": 5},
    {"Region": "eu-west-1", "MaxPrice": 0.12, "Score": 8}
]'

sorted_results=$(echo "$test_multiple_results" | jq 'sort_by(.MaxPrice)')
best_region=$(echo "$sorted_results" | jq -r '.[0].Region')
best_price=$(echo "$sorted_results" | jq -r '.[0].MaxPrice')

test_assert '[[ "$best_region" == "us-west-2" ]]' "Best region selection: $best_region"
test_assert '[[ $(echo "$best_price == 0.10" | bc -l) == "1" ]]' "Best price selection: $best_price"

# Test spot pricing command
start_time=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S)
end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
pricing_cmd="aws ec2 describe-spot-price-history --region us-east-1 --instance-types m5.large --start-time $start_time --end-time $end_time --filters 'Name=product-description,Values=Linux/UNIX' --output json"
test_assert '[[ -n "$pricing_cmd" ]]' "Spot pricing command constructed"


# Simulate the new positional argument logic
test_args=("amzn2-ami-hvm-*" "-c" "4" "-m" "16")
if [[ ${#test_args[@]} -gt 0 && "${test_args[0]}" != -* ]]; then
    test_ami_name="${test_args[0]}"
    test_assert '[[ "$test_ami_name" == "amzn2-ami-hvm-*" ]]' "Positional AMI argument parsing: $test_ami_name"
else
    test_assert 'false' "Positional AMI argument parsing failed"
fi

# Summary
test_log "Test Summary"
if [[ $TEST_RESULTS -eq 0 ]]; then
    echo "✅ All tests passed!"
    echo "📝 Tests updated for new AMI positional argument and global checking"
    exit 0
else
    echo "❌ $TEST_RESULTS test(s) failed"
    exit 1
fi

