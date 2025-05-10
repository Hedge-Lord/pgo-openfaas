package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"os/signal"
	"runtime/pprof"
	"syscall"
	"time"
)

// Request defines the input structure
type Request struct {
	Iterations int    `json:"iterations"`
	Complexity int    `json:"complexity"`
	Name       string `json:"name"`
}

// Response defines the output structure
type Response struct {
	Result     float64 `json:"result"`
	Duration   string  `json:"duration"`
	Iterations int     `json:"iterations"`
	Name       string  `json:"name"`
}

// CPUIntensiveTask simulates a CPU-heavy workload with branches (good for PGO)
func CPUIntensiveTask(iterations, complexity int) float64 {
	result := 0.0
	
	// Ensure complexity is at least 3 to avoid division by zero
	if complexity < 3 {
		complexity = 3
	}
	
	for i := 1; i < iterations+1; i++ { // Start from 1 to avoid log(0)
		// Branchy code for PGO to optimize
		if i%2 == 0 {
			result += math.Sin(float64(i) * 0.01)
		} else {
			result += math.Cos(float64(i) * 0.01)
		}
		
		// More branches
		switch i % complexity {
		case 0:
			result += math.Sqrt(float64(i))
		case 1:
			result += math.Log(float64(i))
		case 2:
			result += math.Exp(math.Min(float64(i) * 0.01, 10.0)) // Limit exp input to avoid overflow
		default:
			result += float64(i) * 0.01
		}
	}
	
	// Handle potential infinity
	if math.IsInf(result, 0) || math.IsNaN(result) {
		return 0.0
	}
	
	return result
}

// Handle processes the incoming request
func Handle(ctx context.Context, in []byte) ([]byte, error) {
	var req Request
	
	// Default values
	req.Iterations = 100000
	req.Complexity = 4
	req.Name = "world"
	
	// Try to parse JSON
	_ = json.Unmarshal(in, &req)
	
	startTime := time.Now()
	result := CPUIntensiveTask(req.Iterations, req.Complexity)
	duration := time.Since(startTime)
	
	resp := Response{
		Result:     result,
		Duration:   duration.String(),
		Iterations: req.Iterations,
		Name:       req.Name,
	}
	
	return json.Marshal(resp)
}

// init sets up pprof profiling on SIGTERM
func init() {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGTERM)
	go func() {
		<-ch
		fmt.Println("SIGTERM received, starting profile capture")
		
		f, err := os.Create("/tmp/cpu.pprof")
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to create profile file: %v\n", err)
			return
		}
		defer f.Close()
		
		if err := pprof.StartCPUProfile(f); err != nil {
			fmt.Fprintf(os.Stderr, "Failed to start CPU profile: %v\n", err)
			return
		}
		
		// Simulate some load for profiling
		CPUIntensiveTask(500000, 10)
		
		pprof.StopCPUProfile()
		fmt.Println("Profile captured and written to /tmp/cpu.pprof")
		
		// Exit after profiling is complete
		time.Sleep(100 * time.Millisecond)
		os.Exit(0)
	}()
} 