# PGO vs Plain AOT Experiment with OpenFaaS

Compare Profile-Guided Optimization (PGO) against plain Ahead-of-Time (AOT) compilation in Go functions running on OpenFaaS.

## Status: Work in Progress

This project is currently a work in progress. Some parts may need manual intervention.

## Repository Structure

```
.
├── README.md
├── STEPS.md           # Step-by-step experiment guide
├── scripts/
    └── run_experiment.sh  # Automated experiment script
│   └── setup.sh       # Sets up OpenFaaS and dependencies
└── functions/
    └── bench/
        ├── handler.go     # Go function with pprof profiling
        ├── main.go        # Main function for HTTP server
        ├── go.mod         # Go module file
        ├── Dockerfile     # Standard build
        ├── Dockerfile.pgo # PGO-optimized build
        └── stack.yml      # OpenFaaS deployment config
```

## Quick Start

1. **Setup OpenFaaS**:
   ```bash
   ./scripts/setup.sh
   ```
   This will install OpenFaaS and its dependencies. You may need to fix Docker issues manually.

2. **Run the experiment**:
   ```bash
   ./run_experiment.sh
   ```
   Or follow the manual steps in [STEPS.md](STEPS.md) for more control.

## How It Works

1. **Baseline Function**: Standard Go build
2. **Profile Collection**: Captures CPU profile on SIGTERM using nerdctl
3. **PGO Version**: Built with `-pgo` flag using the collected profile
4. **Benchmark**: Compare performance between versions

## Key Optimizations

The experiment uses a CPU-intensive workload with branchy code that benefits from PGO:
- Conditional branches (if/else)
- Switch statements
- Math functions with different execution paths

PGO helps the compiler make better inlining, branch prediction, and code layout decisions based on actual execution patterns.
