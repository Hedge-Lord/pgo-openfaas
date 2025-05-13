#!/bin/bash
set -e

# ────────── styling helpers ─────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
header() { echo -e "${GREEN}$1${NC}"; }
step()   { echo -e "${BLUE}Step $1: $2${NC}"; }
info()   { echo -e "${BLUE}$1${NC}"; }
ok()     { echo -e "${GREEN}$1${NC}"; }
die()    { echo -e "${RED}$1${NC}"; exit 1; }

# ────────── config ──────────────────────────────────────────────────
GATEWAY="http://127.0.0.1:8080"
ITERATIONS="${1:-500000}"   # inner‑loop work
REQS="${2:-1000}"           # total requests per hey run
CONC="${3:-20}"             # concurrency
COMPLEXITY=4

# ────────── generic parsers  (100 % awk) ────────────────────────────
parse() {                 # file metric
  case $2 in
    avg) awk '$1=="Average:"      {print $2}'      "$1";;
    p95) awk '$1=="95%"           {print $(NF-1)}' "$1";;
    p99) awk '$1=="99%"           {print $(NF-1)}' "$1";;
    rps) awk '$1=="Requests/sec:" {print $2}'      "$1";;
  esac
}

# ────────── deps ────────────────────────────────────────────────────
command -v hey >/dev/null || { info "Installing hey…"; go install github.com/rakyll/hey@latest; }

# ────────── build/deploy helpers ────────────────────────────────────
build_and_deploy () {      # fn dockerfile
  local fn=$1; shift
  local df=$1; shift || true
  info "Building $fn …"
  docker build -t $fn:latest ${df:+-f $df} . >/dev/null
  docker tag  $fn:latest localhost:5000/$fn:latest
  docker push localhost:5000/$fn:latest   >/dev/null
  faas-cli deploy -f stack.yml --filter $fn --gateway $GATEWAY
  sleep 3
}

bench () {                 # fn outfile mode
  local MODE=${3:-json}
  hey -n $REQS -c $CONC -m POST \
      -H 'Content-Type: application/json' \
      -d "{\"iterations\":$ITERATIONS,\"name\":\"test\",\"mode\":\"$MODE\"}" \
      $GATEWAY/function/$1 > "$2"
}

# ────────── main flow ───────────────────────────────────────────────
cd functions/bench || die "run from repo root"

header "Starting PGO experiment"

# baseline build/prof‑warm
step 1 "build & deploy baseline"
build_and_deploy bench Dockerfile

step 2 "profile warm‑up"
hey -n $REQS -c $CONC -m POST \
    -H 'Content-Type: application/json' \
    -d "{\"iterations\":$ITERATIONS,\"complexity\":$COMPLEXITY}" \
    $GATEWAY/function/bench >/dev/null
sudo nerdctl --namespace=openfaas-fn kill -s SIGTERM bench
sleep 2
sudo nerdctl --namespace=openfaas-fn cp bench:/tmp/cpu.pprof ./cpu.pprof || die "no profile"
go tool pprof -proto cpu.pprof > default.pgo
ok "profile captured & converted"

# redeploy *fresh* baseline + PGO
faas-cli remove -f stack.yml --filter bench --gateway $GATEWAY
step 3 "deploy fresh baseline + pgo"
build_and_deploy bench      Dockerfile
build_and_deploy bench-pgo  Dockerfile.pgo

# benchmark
step 4 "benchmarking"
bench bench     baseline.txt json
bench bench-pgo pgo.txt json

# compare
BASE_AVG=$(parse baseline.txt avg); PGO_AVG=$(parse pgo.txt avg)
BASE_P95=$(parse baseline.txt p95); PGO_P95=$(parse pgo.txt p95)
BASE_P99=$(parse baseline.txt p99); PGO_P99=$(parse pgo.txt p99)

AVG_WIN=$(echo "scale=2;($BASE_AVG-$PGO_AVG)/$BASE_AVG*100" | bc)
P95_WIN=$(echo "scale=2;($BASE_P95-$PGO_P95)/$BASE_P95*100" | bc)
P99_WIN=$(echo "scale=2;($BASE_P99-$PGO_P99)/$BASE_P99*100" | bc)

ok  "Avg  latency improvement : ${AVG_WIN}%"
ok  "p95  latency improvement : ${P95_WIN}%"
ok  "p99  latency improvement : ${P99_WIN}%"

echo
info "Raw baseline:"
grep -A5 "Average" baseline.txt
info "Raw PGO:"
grep -A5 "Average" pgo.txt

faas-cli remove -f stack.yml --gateway $GATEWAY
