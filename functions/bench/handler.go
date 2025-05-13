package main

import (
	"context"
	"encoding/json"
	"errors"
	"math/rand"
	"os"
	"os/signal"
	"regexp"
	"runtime"
	"runtime/pprof"
	"strings"
	"syscall"
	"time"
)

/* ---------- API types ---------- */

type Mode string

const (
	ModeJSON  Mode = "json"  // hot path
	ModeRegex Mode = "regex" // cold but realistic
)

type Request struct {
	Iterations int    `json:"iterations"`
	Name       string `json:"name"`
	Mode       Mode   `json:"mode,omitempty"`
}

type Response struct {
	Duration string `json:"duration"`
	P95      int    `json:"p95_estimate"`
	Name     string `json:"name"`
}

/* ---------- interface & impl ---------- */

type Processor interface {
	Process(string) int
}

type jsonProc struct {
	cache map[string]int
}

func (j *jsonProc) Process(s string) int {
	if v, ok := j.cache[s]; ok {
		return v
	}
	var obj map[string]any
	_ = json.Unmarshal([]byte(s), &obj)
	v := len(obj)
	j.cache[s] = v
	return v
}

type regexProc struct {
	re *regexp.Regexp
}

func (r *regexProc) Process(s string) int {
	if r.re.MatchString(s) {
		return 1
	}
	return 0
}

/* ---------- helpers ---------- */

var jsonSamples = []string{
	`{"user":"alice","id":42,"enabled":true}`,
	`{"user":"bob","items":[1,2,3],"score":17}`,
	`{"user":"eve","meta":{"ip":"1.2.3.4"}}`,
}
var regexSamples = []string{
	"GET /index.html HTTP/1.1",
	"POST /api/v1/item HTTP/1.1",
	"DELETE /user/97 HTTP/1.1",
}

func buildProcessor(m Mode) Processor {
	switch m {
	case ModeRegex:
		return &regexProc{regexp.MustCompile(`^DELETE`)}
	default:
		return &jsonProc{cache: make(map[string]int)}
	}
}

/* ---------- Handle ---------- */

func Handle(_ context.Context, in []byte) ([]byte, error) {
	// cheap parse
	req := Request{Iterations: 100_000, Mode: ModeJSON, Name: "world"}
	if len(in) > 0 {
		if err := json.Unmarshal(in, &req); err != nil {
			return nil, err
		}
	}
	if req.Iterations <= 0 {
		return nil, errors.New("iterations must be >0")
	}

	proc := buildProcessor(req.Mode)

	start := time.Now()
	p95Est := hotLoop(proc, req.Iterations, req.Mode)
	dur := time.Since(start)

	resp := Response{Duration: dur.String(), P95: p95Est, Name: req.Name}
	return json.Marshal(resp)
}

/* ---------- Hot loop ---------- */

func hotLoop(p Processor, iters int, mode Mode) int {
	var sample []string
	if mode == ModeRegex {
		sample = regexSamples
	} else {
		sample = jsonSamples
	}
	counts := make([]int, 0, iters)

	for i := 0; i < iters; i++ {
		s := sample[i%len(sample)]
		// interface dispatch here (PGO devirtualises)
		v := p.Process(s)

		// rare extra branch: 1 % enters slow path
		if i%97 == 0 {
			v += coldPath(s)
		}
		counts = append(counts, v)
	}

	// quick median‑of‑ninety‑fifth ish
	return counts[len(counts)*95/100]
}

//go:noinline
func coldPath(s string) int {
	// force a cold code path: title‑case & heavy strings
	time.Sleep(20 * time.Microsecond) // simulate I/O
	return len(strings.Title(s))
}

/* ---------- profiling bootstrap ---------- */

func init() {
	f, _ := os.Create("/tmp/cpu.pprof")
	_ = pprof.StartCPUProfile(f)

	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-ch
		pprof.StopCPUProfile()
		f.Close()
		runtime.GC()
		os.Exit(0)
	}()
	rand.Seed(time.Now().UnixNano())
}
