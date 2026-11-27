package main

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func fixtureECHConfig(t *testing.T) (tls.EncryptedClientHelloKey, []byte) {
	t.Helper()
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	publicName := "example.com"
	content := []byte{1, 0, 0x20, 0, 32}
	content = append(content, key.PublicKey().Bytes()...)
	content = append(content, 0, 4, 0, 1, 0, 1, 32, byte(len(publicName)))
	content = append(content, publicName...)
	content = append(content, 0, 0)
	config := binary.BigEndian.AppendUint16([]byte{0xfe, 0x0d}, uint16(len(content)))
	config = append(config, content...)
	list := binary.BigEndian.AppendUint16(nil, uint16(len(config)))
	return tls.EncryptedClientHelloKey{Config: config, PrivateKey: key.Bytes(), SendAsRetry: true}, append(list, config...)
}

func TestECHNegotiationAndCertificateValidation(t *testing.T) {
	key, config := fixtureECHConfig(t)
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if !request.TLS.ECHAccepted {
			t.Error("request arrived without a negotiated ECH connection")
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	server.TLS = &tls.Config{MinVersion: tls.VersionTLS13, EncryptedClientHelloKeys: []tls.EncryptedClientHelloKey{key}}
	server.StartTLS()
	defer server.Close()

	dial := func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
	}
	roots := x509.NewCertPool()
	roots.AddCert(server.Certificate())

	transport, err := newTransport("example.com", request{ECHConfig: config}, dial)
	if err != nil {
		t.Fatal(err)
	}
	defer transport.CloseIdleConnections()
	transport.TLSClientConfig.RootCAs = roots
	client := &http.Client{Transport: transport}
	res, err := client.Get("https://example.com")
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusNoContent || res.TLS == nil || !res.TLS.ECHAccepted {
		t.Fatal("ECH was not accepted")
	}

	wrongName, err := newTransport("another.example", request{ECHConfig: config}, dial)
	if err != nil {
		t.Fatal(err)
	}
	defer wrongName.CloseIdleConnections()
	wrongName.TLSClientConfig.RootCAs = roots
	client.Transport = wrongName
	var hostnameError x509.HostnameError
	if _, err := client.Get("https://another.example"); !errors.As(err, &hostnameError) {
		t.Fatalf("expected a hostname mismatch, got %v", err)
	}

	untrusted, err := newTransport("example.com", request{ECHConfig: config}, dial)
	if err != nil {
		t.Fatal(err)
	}
	defer untrusted.CloseIdleConnections()
	untrusted.TLSClientConfig.RootCAs = x509.NewCertPool()
	client.Transport = untrusted
	var unknownAuthority x509.UnknownAuthorityError
	if _, err := client.Get("https://example.com"); !errors.As(err, &unknownAuthority) {
		t.Fatalf("expected an untrusted certificate error, got %v", err)
	}
}

func TestProtocolRejectsDifferentOrigin(t *testing.T) {
	var output bytes.Buffer
	err := serve(bytes.NewBufferString("{\"URL\":\"https://example.test/\",\"Method\":\"GET\"}\n"), &output)
	if err == nil || !bytes.Contains(output.Bytes(), []byte("echInvalidRequest")) {
		t.Fatal("expected the helper to reject a request outside its configured origin")
	}
}

func TestProxyIsExplicit(t *testing.T) {
	result, err := newTransport(targetHost, request{ProxyURL: "socks5://127.0.0.1:1080"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequest("GET", "https://"+targetHost, nil)
	if err != nil {
		t.Fatal(err)
	}
	proxy, err := result.Proxy(req)
	if err != nil || proxy == nil || proxy.Scheme != "socks5" {
		t.Fatal("explicit proxy was not retained")
	}
}

// Exercise a rotated configuration through an HTTP CONNECT tunnel. The server
// must receive one application request on the successful ECH connection.
func TestECHRetriesAuthenticatedConfigThroughProxy(t *testing.T) {
	key, current := fixtureECHConfig(t)
	_, stale := fixtureECHConfig(t)
	var requests atomic.Int32
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		if !r.TLS.ECHAccepted || r.Host != "example.com" {
			t.Error("request did not reach the verified ECH origin")
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	server.TLS = &tls.Config{MinVersion: tls.VersionTLS13, EncryptedClientHelloKeys: []tls.EncryptedClientHelloKey{key}}
	server.StartTLS()
	defer server.Close()

	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodConnect || r.Host != "example.com:443" {
			t.Errorf("unexpected proxy request: %s %s", r.Method, r.Host)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		origin, err := net.Dial("tcp", server.Listener.Addr().String())
		if err != nil {
			t.Error(err)
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		defer origin.Close()
		client, buffered, err := http.NewResponseController(w).Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		defer client.Close()
		if _, err := buffered.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
			t.Error(err)
			return
		}
		if err := buffered.Flush(); err != nil {
			t.Error(err)
			return
		}
		go func() {
			_, _ = io.Copy(origin, buffered)
			_ = origin.Close()
		}()
		_, _ = io.Copy(client, origin)
	}))
	defer proxy.Close()

	transport, err := newTransport("example.com", request{ECHConfig: stale, ProxyURL: proxy.URL}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer transport.CloseIdleConnections()
	roots := x509.NewCertPool()
	roots.AddCert(server.Certificate())
	transport.TLSClientConfig.RootCAs = roots
	req, err := http.NewRequest(http.MethodGet, "https://example.com/", nil)
	if err != nil {
		t.Fatal(err)
	}
	res, used, err := roundTripECH(transport, req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusNoContent || !res.TLS.ECHAccepted || !bytes.Equal(used, current) || requests.Load() != 1 {
		t.Fatal("the authenticated ECH retry did not complete")
	}
}

func TestECHDoesNotSendARequestWhenServerStopsOfferingECH(t *testing.T) {
	_, config := fixtureECHConfig(t)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("received an HTTP request without ECH")
	}))
	defer server.Close()
	dial := func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
	}
	transport, err := newTransport("example.com", request{ECHConfig: config}, dial)
	if err != nil {
		t.Fatal(err)
	}
	defer transport.CloseIdleConnections()
	roots := x509.NewCertPool()
	roots.AddCert(server.Certificate())
	transport.TLSClientConfig.RootCAs = roots
	req, err := http.NewRequest(http.MethodGet, "https://example.com/", nil)
	if err != nil {
		t.Fatal(err)
	}
	res, used, err := roundTripECH(transport, req)
	var rejection *tls.ECHRejectionError
	if res != nil || len(used) != 0 || !errors.As(err, &rejection) || len(rejection.RetryConfigList) != 0 {
		t.Fatalf("expected ECH rejection without retry configs, got %v", err)
	}
}
