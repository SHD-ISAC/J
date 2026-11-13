package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	targetHost = "exhentai.org"
	maxHeader  = 64 << 10
)

type request struct {
	URL           string
	Method        string
	Headers       http.Header
	HasBody       bool
	ECHConfig     []byte
	ProxyURL      string
	ConnectMillis int
	ReceiveMillis int
}

type response struct {
	Status      int         `json:"status,omitempty"`
	Headers     http.Header `json:"headers,omitempty"`
	ECHAccepted bool        `json:"echAccepted,omitempty"`
	Error       string      `json:"error,omitempty"`
}

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		_, _ = os.Stdout.WriteString("jhentai-ech 1\n")
		return
	}
	if err := serve(os.Stdin, os.Stdout); err != nil {
		os.Exit(1)
	}
}

func serve(input io.Reader, output io.Writer) error {
	r := bufio.NewReaderSize(input, maxHeader)
	line, err := r.ReadSlice('\n')
	if err != nil {
		return fail(output, "echInvalidRequest")
	}
	var message request
	if err := json.Unmarshal(line, &message); err != nil {
		return fail(output, "echInvalidRequest")
	}

	endpoint, err := url.Parse(message.URL)
	if err != nil || endpoint.Scheme != "https" || endpoint.Hostname() != targetHost || (endpoint.Port() != "" && endpoint.Port() != "443") || endpoint.User != nil {
		return fail(output, "echInvalidRequest")
	}
	if len(message.ECHConfig) == 0 {
		return fail(output, "echConfigUnavailable")
	}

	var body io.Reader
	if message.HasBody {
		body = r
	}
	req, err := http.NewRequestWithContext(context.Background(), message.Method, endpoint.String(), body)
	if err != nil {
		return fail(output, "echInvalidRequest")
	}
	for key, values := range message.Headers {
		switch strings.ToLower(key) {
		case "host", "connection", "proxy-authorization", "proxy-connection",
			"transfer-encoding", "upgrade":
			continue
		case "content-length":
			if len(values) == 1 {
				if size, err := strconv.ParseInt(values[0], 10, 64); err == nil && size > 0 {
					req.ContentLength = size
				}
			}
		default:
			req.Header[http.CanonicalHeaderKey(key)] = values
		}
	}

	transport, err := newTransport(targetHost, message, nil)
	if err != nil {
		return fail(output, "echProxyUnsupported")
	}
	defer transport.CloseIdleConnections()
	result, err := transport.RoundTrip(req)
	if err != nil {
		var rejected *tls.ECHRejectionError
		var timeout net.Error
		switch {
		case errors.As(err, &rejected):
			return fail(output, "echRejected")
		case errors.As(err, &timeout) && timeout.Timeout():
			return fail(output, "echTimedOut")
		default:
			return fail(output, "echFailed")
		}
	}
	defer result.Body.Close()
	if result.TLS == nil || !result.TLS.ECHAccepted {
		return fail(output, "echRejected")
	}
	if err := json.NewEncoder(output).Encode(response{
		Status: result.StatusCode, Headers: result.Header, ECHAccepted: true,
	}); err != nil {
		return err
	}
	_, err = io.Copy(output, result.Body)
	return err
}

func fail(output io.Writer, category string) error {
	_ = json.NewEncoder(output).Encode(response{Error: category})
	return errors.New(category)
}

func newTransport(host string, message request, dial func(context.Context, string, string) (net.Conn, error)) (*http.Transport, error) {
	connect := time.Duration(message.ConnectMillis) * time.Millisecond
	receive := time.Duration(message.ReceiveMillis) * time.Millisecond
	if connect <= 0 {
		connect = 30 * time.Second
	}
	if dial == nil {
		dial = (&net.Dialer{Timeout: connect}).DialContext
	}
	transport := &http.Transport{
		DialContext:            dial,
		TLSHandshakeTimeout:    connect,
		ResponseHeaderTimeout:  receive,
		ForceAttemptHTTP2:      true,
		MaxResponseHeaderBytes: maxHeader,
		TLSClientConfig: &tls.Config{
			ServerName:                     host,
			MinVersion:                     tls.VersionTLS13,
			EncryptedClientHelloConfigList: message.ECHConfig,
		},
	}
	if message.ProxyURL != "" {
		proxy, err := url.Parse(message.ProxyURL)
		if err != nil || proxy.Hostname() == "" || proxy.Port() == "" || proxy.Path != "" || proxy.RawQuery != "" || proxy.Fragment != "" {
			return nil, errors.New("invalid proxy endpoint")
		}
		switch proxy.Scheme {
		case "http", "socks5":
			transport.Proxy = http.ProxyURL(proxy)
		default:
			return nil, errors.New("unsupported proxy type")
		}
	}
	return transport, nil
}
