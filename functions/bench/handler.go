package main

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"math/rand"
	"os"
	"os/signal"
	"runtime"
	"runtime/pprof"
	"syscall"
	"time"
)

// ---------- Request/Response ----------

type Request struct {
	Iterations int    `json:"iterations"`
	Complexity int    `json:"complexity"`
	Name       string `json:"name"`
}

type Response struct {
	Result     float64 `json:"result"`
	Duration   string  `json:"duration"`
	Iterations int     `json:"iterations"`
	Name       string  `json:"name"`
}

// ---------- JSON parsing (cold) ----------

func parseRequest(in []byte) (Request, error) {
	var req Request
	req.Iterations = 100_000
	req.Complexity = 4
	req.Name = "world"

	if len(in) == 0 {
		return req, nil
	}
	if err := json.Unmarshal(in, &req); err != nil {
		return req, err
	}
	if req.Complexity < 3 {
		return req, errors.New("complexity must be ≥3")
	}
	return req, nil
}

// ---------- Hot numeric loop ----------

//go:nosplit
func cpuIntensive(iter, comp int) float64 {
	var res float64
	for i := 1; i <= iter; i++ {
		// Cheap predictable branch
		if i&1 == 0 {
			res += math.Sin(float64(i) * 0.01)
		} else {
			res += math.Cos(float64(i) * 0.01)
		}

		// Intentional *rare* branch — ~1 % hit rate
		if isRare(i) {
			res += expensiveColdPath(i)
			continue
		}

		switch i % comp {
		case 0:
			res += math.Sqrt(float64(i))
		case 1:
			res += math.Log(float64(i))
		case 2:
			res += math.Exp(math.Min(float64(i)*0.01, 10))
		default:
			res += float64(i) * 0.01
		}
	}
	return res
}

// Marked noinline so PGO can keep it cold.
//go:noinline
func expensiveColdPath(i int) float64 {
	// Pretend we call into a heavy lib once in a while
	time.Sleep(time.Microsecond) // IO/GC‐ish pause
	return math.Pow(float64(i), 1.3)
}

func isRare(i int) bool { return i%97 == 0 }

// ---------- FaaS entry ----------

func Handle(ctx context.Context, in []byte) ([]byte, error) {
	req, err := parseRequest(in)
	if err != nil {
		return nil, err
	}

	start := time.Now()
	val := cpuIntensive(req.Iterations, req.Complexity)
	dur := time.Since(start)

	resp := Response{val, dur.String(), req.Iterations, req.Name}
	return json.Marshal(resp)
}

// ---------- Profiling bootstrap ----------

func init() {
	f, _ := os.Create("/tmp/cpu.pprof")
	_ = pprof.StartCPUProfile(f)

	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-ch
		pprof.StopCPUProfile()
		f.Close()
		runtime.GC() // flush profile buffers
		os.Exit(0)
	}()
	// seed RNG once
	rand.Seed(time.Now().UnixNano())
}
