# PGO Experiment Steps

These steps should be run on your CloudLab node after setting up OpenFaaS using `scripts/setup.sh`.

## 0. Setup Local Docker Registry (if needed)

If OpenFaaS can't use local Docker images, set up a local registry:

```bash
# Start a local registry
docker run -d -p 5000:5000 --restart=always --name registry registry:2

# Tag and push images to local registry
docker tag bench:latest localhost:5000/bench:latest
docker push localhost:5000/bench:latest

# Update stack.yml to use local registry
# Change image: bench:latest to image: localhost:5000/bench:latest
```

## 1. Deploy Baseline Function

```bash
cd functions/bench
docker build -t bench:latest .

# Tag for local registry
docker tag bench:latest localhost:5000/bench:latest
docker push localhost:5000/bench:latest

# Deploy
faas-cli deploy -f stack.yml --filter bench
```

## 2. Test Function

```bash
curl -X POST -d '{"iterations":100000,"complexity":4,"name":"test"}' http://127.0.0.1:8080/function/bench
```

## 3. Collect Profile

```bash
sudo nerdctl --namespace=openfaas-fn kill -s SIGTERM bench

# Give Go a moment
sleep 2

sudo nerdctl --namespace=openfaas-fn cp bench:/tmp/cpu.pprof ./cpu.pprof

# sanity‑check
ls -lh cpu.pprof

go tool pprof -proto cpu.pprof > default.pgo
```

## 4. Deploy PGO Version

```bash
docker build -t bench-pgo:latest -f Dockerfile.pgo .

# Tag for local registry
docker tag bench-pgo:latest localhost:5000/bench-pgo:latest
docker push localhost:5000/bench-pgo:latest

# Deploy
faas-cli deploy -f stack.yml --filter bench-pgo
```

## 5. Benchmark and Compare

```bash
# Benchmark both versions
hey -n 50 -c 1 -m POST -d '{"iterations":100000,"complexity":4,"name":"test"}' \
  http://127.0.0.1:8080/function/bench > baseline_results.txt

hey -n 50 -c 1 -m POST -d '{"iterations":100000,"complexity":4,"name":"test"}' \
  http://127.0.0.1:8080/function/bench-pgo > pgo_results.txt

# Compare results
echo "Baseline Results:"
cat baseline_results.txt | grep "Average" -A 5
echo -e "\nPGO Results:"
cat pgo_results.txt | grep "Average" -A 5
```

## 6. Cleanup

```bash
faas-cli remove -f stack.yml
# docker stop registry && docker rm registry  # If you used a local registry
``` 