#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
GATEWAY="http://127.0.0.1:8080"
ITERATIONS=500000
COMPLEXITY=4
BENCHMARK_REQUESTS=1000
BENCHMARK_CONCURRENCY=20

echo -e "${GREEN}Starting PGO experiment...${NC}"

# Navigate to function directory
cd functions/bench

# Step 1: Build and deploy baseline function
echo -e "${BLUE}Step 1: Building and deploying baseline function...${NC}"
docker build -t bench:latest .
docker tag bench:latest localhost:5000/bench:latest
docker push localhost:5000/bench:latest
faas-cli deploy -f stack.yml --filter bench

# Wait for function to be ready
echo -e "${BLUE}Waiting for function to be ready...${NC}"
sleep 5

# Step 2: Test function
echo -e "${BLUE}Step 2: Testing function...${NC}"
RESPONSE=$(curl -s -X POST -d "{\"iterations\":${ITERATIONS},\"complexity\":${COMPLEXITY},\"name\":\"test\"}" ${GATEWAY}/function/bench)
echo "Function response: $RESPONSE"

# Step 3: Collect profile
echo -e "${BLUE}Step 3: Warming up & collecting profile...${NC}"
hey -n ${BENCHMARK_REQUESTS} -c ${BENCHMARK_CONCURRENCY} -m POST \
  -H "Content-Type: application/json" \
  -d "{\"iterations\":${ITERATIONS},\"complexity\":${COMPLEXITY},\"name\":\"profile\"}" \
  ${GATEWAY}/function/bench > /dev/null
sudo nerdctl --namespace=openfaas-fn kill -s SIGTERM bench

# Give Go a moment to generate the profile
echo "Waiting for profile generation..."
sleep 2

# Extract the profile
sudo nerdctl --namespace=openfaas-fn cp bench:/tmp/cpu.pprof ./cpu.pprof

# Check if profile was generated
if [ ! -f ./cpu.pprof ]; then
    echo -e "${RED}Error: Profile was not generated.${NC}"
    exit 1
fi

echo -e "${GREEN}Profile collected: $(ls -lh cpu.pprof)${NC}"

# Convert profile to PGO format
go tool pprof -proto cpu.pprof > default.pgo
echo -e "${GREEN}Profile converted to PGO format.${NC}"

# Step 4: Build and deploy PGO version
echo -e "${BLUE}Step 4: Building and deploying PGO version...${NC}"
docker build -t bench-pgo:latest -f Dockerfile.pgo .
docker tag bench-pgo:latest localhost:5000/bench-pgo:latest
docker push localhost:5000/bench-pgo:latest
faas-cli deploy -f stack.yml --filter bench-pgo

# Wait for PGO function to be ready
echo -e "${BLUE}Waiting for PGO function to be ready...${NC}"
sleep 5

# Step 5: Benchmark and compare
echo -e "${BLUE}Step 5: Benchmarking and comparing...${NC}"

# Make sure hey is installed
if ! command -v hey &> /dev/null; then
    echo -e "${RED}hey not found. Installing...${NC}"
    go install github.com/rakyll/hey@latest
fi

# Benchmark baseline version
echo -e "${BLUE}Benchmarking baseline version...${NC}"
hey -n ${BENCHMARK_REQUESTS} -c ${BENCHMARK_CONCURRENCY} -m POST \
  -H "Content-Type: application/json" \
  -d "{\"iterations\":${ITERATIONS},\"complexity\":${COMPLEXITY},\"name\":\"test\"}" \
  ${GATEWAY}/function/bench > baseline_results.txt

# Benchmark PGO version
echo -e "${BLUE}Benchmarking PGO version...${NC}"
hey -n ${BENCHMARK_REQUESTS} -c ${BENCHMARK_CONCURRENCY} -m POST \
  -H "Content-Type: application/json" \
  -d "{\"iterations\":${ITERATIONS},\"complexity\":${COMPLEXITY},\"name\":\"test\"}" \
  ${GATEWAY}/function/bench-pgo > pgo_results.txt

# Compare results
echo -e "${GREEN}Results comparison:${NC}"
echo -e "${BLUE}Baseline Results:${NC}"
grep "Average" -A 5 baseline_results.txt

echo -e "${BLUE}PGO Results:${NC}"
grep "Average" -A 5 pgo_results.txt

parse_p95 () {
  # $1 = results file
  awk '/ 95% in / { print $3 }' "$1"
}

# Calculate improvement percentage
BASELINE_AVG=$(grep "Average:" baseline_results.txt | awk '{print $2}')
PGO_AVG=$(grep "Average:" pgo_results.txt | awk '{print $2}')
IMPROVEMENT=$(echo "scale=2; (($BASELINE_AVG - $PGO_AVG) / $BASELINE_AVG) * 100" | bc)

BASELINE_P95=$(parse_p95 baseline_results.txt)
PGO_P95=$(parse_p95 pgo_results.txt)
P95_IMPROV=$(echo "scale=2; (($BASELINE_P95 - $PGO_P95) / $BASELINE_P95) * 100" | bc)

echo -e "${GREEN}Average latency improvement: ${AVG_IMPROV}%${NC}"
echo -e "${GREEN}p95 latency improvement:     ${P95_IMPROV}%${NC}"

# Optional cleanup
read -p "Do you want to clean up the deployed functions? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}Cleaning up...${NC}"
    faas-cli remove -f stack.yml
    echo -e "${GREEN}Cleanup complete.${NC}"
fi

echo -e "${GREEN}Experiment complete!${NC}" 