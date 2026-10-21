package tcp

import (
	"fmt"
	"io"
	"net"
	"os"
	"runtime"
	"strconv"
	"sync"
	"syscall"

	"github.com/rootless-containers/rootlesskit/v2/pkg/port"
	"github.com/rootless-containers/rootlesskit/v2/pkg/port/builtin/msg"
	"github.com/sirupsen/logrus"
	"golang.org/x/sys/unix"
)

func Run(socketPath string, spec port.Spec, stopCh <-chan struct{}, stoppedCh chan error, logWriter io.Writer) error {
	ln, err := net.Listen(spec.Proto, net.JoinHostPort(spec.ParentIP, strconv.Itoa(spec.ParentPort)))
	if err != nil {
		fmt.Fprintf(logWriter, "listen: %v\n", err)
		return err
	}
	newConns := make(chan net.Conn)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				fmt.Fprintf(logWriter, "accept: %v\n", err)
				close(newConns)
				return
			}
			newConns <- c
		}
	}()
	go func() {
		defer func() {
			stoppedCh <- ln.Close()
			close(stoppedCh)
		}()
		for {
			select {
			case c, ok := <-newConns:
				if !ok {
					return
				}
				go func() {
					if err := copyConnToChild(c, socketPath, spec, stopCh); err != nil {
						fmt.Fprintf(logWriter, "copyConnToChild: %v\n", err)
						return
					}
				}()
			case <-stopCh:
				return
			}
		}
	}()
	// no wait
	return nil
}

func copyConnToChild(c net.Conn, socketPath string, spec port.Spec, stopCh <-chan struct{}) error {
	defer c.Close()
	// get fd from the child as an SCM_RIGHTS cmsg
	fd, err := msg.ConnectToChildWithRetry(socketPath, spec, 10)
	if err != nil {
		return err
	}
	f := os.NewFile(uintptr(fd), "")
	defer f.Close()
	fc, err := net.FileConn(f)
	if err != nil {
		return err
	}
	defer fc.Close()
	bicopy(c, fc, stopCh)
	return nil
}

func getRawFd(conn net.Conn) (int, error) {
	sconn, ok := conn.(interface {
		SyscallConn() (syscall.RawConn, error)
	})
	if !ok {
		return 0, fmt.Errorf("connection does not support SyscallConn")
	}
	rawConn, err := sconn.SyscallConn()
	if err != nil {
		return 0, err
	}
	var fdVal int
	err = rawConn.Control(func(fd uintptr) {
		fdVal = int(fd)
	})
	if err != nil {
		return 0, err
	}
	return fdVal, nil
}

// waitForFd blocks until fd is ready for events or quitFd becomes readable.
//
// quitFd is the read end of a pipe written by the caller when the connection
// should be torn down.  poll(2) is called with timeout -1 (infinite) so the
// OS thread blocks entirely in the kernel with no periodic Go-scheduler
// wakeups.  This eliminates the 100 ms × N staircase latency that a finite
// timeout causes when the source is momentarily CPU-starved.
func waitForFd(fd int, events int16, quitFd int) error {
	pollFds := []unix.PollFd{
		{Fd: int32(fd), Events: events},
		{Fd: int32(quitFd), Events: unix.POLLIN},
	}
	for {
		n, err := unix.Poll(pollFds, -1) // infinite — wake only on event or quit
		if err != nil {
			if err == unix.EINTR {
				continue
			}
			return err
		}
		if n > 0 {
			// Quit pipe signalled — connection is being torn down.
			if pollFds[1].Revents&unix.POLLIN != 0 {
				return fmt.Errorf("quit")
			}
			if pollFds[0].Revents&(unix.POLLERR|unix.POLLNVAL) != 0 {
				return fmt.Errorf("fd error status")
			}
			// Data ready or peer hung up — let caller splice or read EOF.
			if pollFds[0].Revents&(events|unix.POLLHUP) != 0 {
				return nil
			}
		}
	}
}

func spliceCopy(dstFd, srcFd int, quit <-chan struct{}) error {
	// Splice pipe: intermediate buffer between srcFd and dstFd.
	var pipeFds [2]int
	if err := unix.Pipe2(pipeFds[:], unix.O_CLOEXEC|unix.O_NONBLOCK); err != nil {
		return err
	}
	pipeRead := pipeFds[0]
	pipeWrite := pipeFds[1]
	defer unix.Close(pipeRead)
	defer unix.Close(pipeWrite)

	// Quit pipe: written when quit fires to unblock poll(-1) in waitForFd.
	// This removes the need for a finite poll timeout, eliminating the
	// 100 ms × N staircase delay seen on resource-constrained nodes.
	var quitPipe [2]int
	if err := unix.Pipe2(quitPipe[:], unix.O_CLOEXEC|unix.O_NONBLOCK); err != nil {
		return err
	}
	quitR, quitW := quitPipe[0], quitPipe[1]
	defer unix.Close(quitR)

	// Bridge quit channel → quit pipe in a separate goroutine.
	// done is closed when spliceCopy returns to release this goroutine.
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-quit:
			unix.Write(quitW, []byte{0}) //nolint:errcheck
		case <-done:
		}
		unix.Close(quitW)
	}()

	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	if err := unix.SetNonblock(srcFd, true); err != nil {
		return fmt.Errorf("setnonblock src: %w", err)
	}
	if err := unix.SetNonblock(dstFd, true); err != nil {
		return fmt.Errorf("setnonblock dst: %w", err)
	}

	for {
		n, err := unix.Splice(srcFd, nil, pipeWrite, nil, 65536, unix.SPLICE_F_NONBLOCK|unix.SPLICE_F_MOVE)
		if err != nil {
			if err == unix.EINTR {
				continue
			}
			if err == unix.EAGAIN || err == unix.EWOULDBLOCK {
				if err := waitForFd(srcFd, unix.POLLIN, quitR); err != nil {
					return err
				}
				continue
			}
			return err
		}
		if n == 0 {
			return nil
		}

		inPipe := n
		for inPipe > 0 {
			m, err := unix.Splice(pipeRead, nil, dstFd, nil, int(inPipe), unix.SPLICE_F_NONBLOCK|unix.SPLICE_F_MOVE)
			if err != nil {
				if err == unix.EINTR {
					continue
				}
				if err == unix.EAGAIN || err == unix.EWOULDBLOCK {
					if err := waitForFd(dstFd, unix.POLLOUT, quitR); err != nil {
						return err
					}
					continue
				}
				return err
			}
			if m == 0 {
				return io.ErrUnexpectedEOF
			}
			inPipe -= m
		}
	}
}

// probeSplice checks if the splice(2) system call is supported and not blocked by seccomp
func probeSplice() bool {
	var pipeFds [2]int
	if err := unix.Pipe2(pipeFds[:], unix.O_CLOEXEC|unix.O_NONBLOCK); err != nil {
		return false
	}
	defer unix.Close(pipeFds[0])
	defer unix.Close(pipeFds[1])

	_, err := unix.Splice(pipeFds[0], nil, pipeFds[1], nil, 0, unix.SPLICE_F_NONBLOCK)
	if err != nil {
		if err == unix.ENOSYS || err == unix.EPERM || err == unix.EACCES || err == unix.EINVAL {
			return false
		}
	}
	return true
}

// bicopy is based on libnetwork/cmd/proxy/tcp_proxy.go .
// NOTE: sendfile(2) cannot be used for sockets
func bicopy(x, y net.Conn, quit <-chan struct{}) {
	xFd, errX := getRawFd(x)
	yFd, errY := getRawFd(y)

	// Fallback to standard io.Copy if we cannot get raw fds or splice is unavailable/blocked
	if errX != nil || errY != nil || !probeSplice() {
		var wg sync.WaitGroup
		var broker = func(to, from net.Conn) {
			io.Copy(to, from)
			if fromTCP, ok := from.(*net.TCPConn); ok {
				fromTCP.CloseRead()
			}
			if toTCP, ok := to.(*net.TCPConn); ok {
				toTCP.CloseWrite()
			}
			wg.Done()
		}

		wg.Add(2)
		go broker(x, y)
		go broker(y, x)
		finish := make(chan struct{})
		go func() {
			wg.Wait()
			close(finish)
		}()

		select {
		case <-quit:
		case <-finish:
		}
		x.Close()
		y.Close()
		<-finish
		return
	}

	// We use the raw splice event loop
	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		if err := spliceCopy(yFd, xFd, quit); err != nil {
			logrus.Debugf("spliceCopy x->y error: %v", err)
		}
		if yTCP, ok := y.(*net.TCPConn); ok {
			yTCP.CloseWrite()
		}
		if xTCP, ok := x.(*net.TCPConn); ok {
			xTCP.CloseRead()
		}
	}()

	go func() {
		defer wg.Done()
		if err := spliceCopy(xFd, yFd, quit); err != nil {
			logrus.Debugf("spliceCopy y->x error: %v", err)
		}
		if xTCP, ok := x.(*net.TCPConn); ok {
			xTCP.CloseWrite()
		}
		if yTCP, ok := y.(*net.TCPConn); ok {
			yTCP.CloseRead()
		}
	}()

	finish := make(chan struct{})
	go func() {
		wg.Wait()
		close(finish)
	}()

	select {
	case <-quit:
	case <-finish:
	}
	x.Close()
	y.Close()
	<-finish
}
