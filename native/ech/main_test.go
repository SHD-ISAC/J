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
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
)

func fixtureECHConfig(t *testing.T) (tls.EncryptedClientHelloKey, []byte) {
	t.Helper()
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	publicName := "public.example"
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
