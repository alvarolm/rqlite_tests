package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

const base = "http://localhost:4001"

var client = &http.Client{
	Transport: &http.Transport{
		MaxIdleConns:        512,
		MaxIdleConnsPerHost: 512,
		MaxConnsPerHost:     512,
		IdleConnTimeout:     30 * time.Second,
	},
	Timeout: 60 * time.Second,
}

func post(url string, body []byte) error {
	resp, err := client.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("status %d: %s", resp.StatusCode, b)
	}
	io.Copy(io.Discard, resp.Body)
	return nil
}

func setup(table string) {
	for _, stmt := range []string{
		"DROP TABLE IF EXISTS " + table,
		"CREATE TABLE " + table + " (id INTEGER PRIMARY KEY, v TEXT)",
	} {
		body, _ := json.Marshal([]any{[]any{stmt}})
		if err := post(base+"/db/execute", body); err != nil {
			log.Fatalf("setup: %v", err)
		}
	}
}

func count(table string) int {
	resp, err := client.Get(base + "/db/query?q=SELECT%20COUNT(*)%20FROM%20" + table + "&level=strong")
	if err != nil {
		log.Fatal(err)
	}
	defer resp.Body.Close()
	var r struct {
		Results []struct {
			Values [][]any `json:"values"`
		} `json:"results"`
	}
	json.NewDecoder(resp.Body).Decode(&r)
	if len(r.Results) == 0 || len(r.Results[0].Values) == 0 {
		return 0
	}
	return int(r.Results[0].Values[0][0].(float64))
}

func bench(label, table, url string, n, conc int) time.Duration {
	var wg sync.WaitGroup
	var i int64
	insert := "INSERT INTO " + table + "(v) VALUES(?)"
	lats := make([]time.Duration, n)
	start := time.Now()
	for w := 0; w < conc; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				k := atomic.AddInt64(&i, 1) - 1
				if k >= int64(n) {
					return
				}
				body, _ := json.Marshal([]any{[]any{insert, fmt.Sprintf("row-%d", k)}})
				t0 := time.Now()
				if err := post(url, body); err != nil {
					log.Fatalf("%s: %v", label, err)
				}
				lats[k] = time.Since(t0)
			}
		}()
	}
	wg.Wait()
	d := time.Since(start)
	sort.Slice(lats, func(a, b int) bool { return lats[a] < lats[b] })
	pct := func(p float64) time.Duration {
		idx := int(float64(n-1) * p)
		return lats[idx].Truncate(time.Microsecond)
	}
	fmt.Printf("%-14s table=%-18s conc=%-4d n=%-6d total=%-12v per-op=%-12v ops/s=%.1f p50=%v p95=%v p99=%v max=%v\n",
		label, table, conc, n, d.Truncate(time.Microsecond),
		(d / time.Duration(n)).Truncate(time.Microsecond),
		float64(n)/d.Seconds(), pct(0.50), pct(0.95), pct(0.99),
		lats[n-1].Truncate(time.Microsecond))
	return d
}

func main() {
	n := flag.Int("n", 5000, "total inserts per run")
	conc := flag.Int("c", 64, "concurrent workers")
	mode := flag.String("mode", "all", "which mode(s) to run: normal | queued | queued_wait | all")
	flag.Parse()

	now := time.Now()

	allRuns := []struct {
		key, label, table, url string
		postSleep              time.Duration
	}{
		{"normal", "normal", "bench_normal", base + "/db/execute", 0},
		/*
			{"queued", "queued", "bench_queued", base + "/db/execute?queue", 2 * time.Second},
			{"queued_wait", "queued+wait", "bench_queued_wait", base + "/db/execute?queue&wait&timeout=30s", 0},
		*/
	}
	for _, r := range allRuns {
		if *mode != "all" && *mode != r.key {
			continue
		}
		setup(r.table)
		bench(r.label, r.table, r.url, *n, *conc)
		if r.postSleep > 0 {
			time.Sleep(r.postSleep)
		}
		fmt.Printf("  committed rows in %s: %d\n\n", r.table, count(r.table))
	}

	fmt.Println("REQUESTS TOOK, %s", time.Since(now))
}
