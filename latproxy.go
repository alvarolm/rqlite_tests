// latproxy: simple TCP proxy that injects a fixed delay on every forwarded
// chunk in both directions. Used to simulate inter-node network latency.
package main

import (
	"flag"
	"io"
	"log"
	"net"
	"time"
)

func pipe(dst net.Conn, src net.Conn, delay time.Duration, done chan<- struct{}) {
	defer func() { done <- struct{}{} }()
	buf := make([]byte, 32*1024)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			if delay > 0 {
				time.Sleep(delay)
			}
			if _, werr := dst.Write(buf[:n]); werr != nil {
				return
			}
		}
		if err != nil {
			if cw, ok := dst.(interface{ CloseWrite() error }); ok {
				cw.CloseWrite()
			}
			if err != io.EOF {
				// benign on shutdown; don't spam
			}
			return
		}
	}
}

func handle(c net.Conn, target string, delay time.Duration) {
	defer c.Close()
	t, err := net.Dial("tcp", target)
	if err != nil {
		log.Printf("dial %s: %v", target, err)
		return
	}
	defer t.Close()
	done := make(chan struct{}, 2)
	go pipe(t, c, delay, done)
	go pipe(c, t, delay, done)
	<-done
}

func main() {
	listen := flag.String("listen", "", "listen addr, e.g. :14002")
	target := flag.String("target", "", "target addr, e.g. localhost:4002")
	delay := flag.Duration("delay", 0, "per-chunk one-way delay (e.g. 20ms)")
	flag.Parse()
	if *listen == "" || *target == "" {
		log.Fatal("both -listen and -target are required")
	}
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("latproxy %s -> %s delay=%v", *listen, *target, *delay)
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			return
		}
		go handle(c, *target, *delay)
	}
}
