package singbox

import (
	"net"
	"testing"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing/service"

	"github.com/cedar2025/xboard-node/internal/config"
	"github.com/cedar2025/xboard-node/internal/kernel"
	"github.com/cedar2025/xboard-node/internal/model"
)

// freePort returns a currently unused TCP port.
func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func testSocksNode(port int, outbounds []model.OutboundConfig) *model.NodeSpec {
	return &model.NodeSpec{
		Protocol:        "socks",
		ListenIP:        "0.0.0.0",
		ServerPort:      port,
		CustomOutbounds: outbounds,
	}
}

func socksOutbound(tag string, port int) model.OutboundConfig {
	return model.OutboundConfig{
		Tag:      tag,
		Protocol: "socks",
		Settings: map[string]any{"server": "127.0.0.1", "server_port": port},
	}
}

func runningOutboundTags(t *testing.T, s *SingBox) map[string]bool {
	t.Helper()
	om := service.FromContext[adapter.OutboundManager](s.ctx)
	if om == nil {
		t.Fatal("outbound manager not available")
	}
	tags := make(map[string]bool)
	for _, ob := range om.Outbounds() {
		tags[ob.Tag()] = true
	}
	return tags
}

// TestReloadRebuildsKernelWhenOutboundsChange covers the regression this fork
// fixes: panel edits to custom outbounds used to be ignored by Reload until the
// node process was restarted.
func TestReloadRebuildsKernelWhenOutboundsChange(t *testing.T) {
	port := freePort(t)
	users := []model.UserSpec{{ID: 1, UUID: "11111111-1111-1111-1111-111111111111"}}
	s := New(config.KernelConfig{Type: "sing-box", LogLevel: "info"})
	ncA := testSocksNode(port, []model.OutboundConfig{socksOutbound("proxy-a", 1080)})
	if err := s.Start(ncA, users, kernel.TLSCert{}); err != nil {
		t.Fatalf("start kernel: %v", err)
	}
	defer s.Stop()

	if !s.IsRunning() {
		t.Fatal("kernel should be running after Start")
	}
	firstBox := s.box
	if tags := runningOutboundTags(t, s); !tags["proxy-a"] {
		t.Fatalf("proxy-a missing from outbound table: %v", tags)
	}

	// User-only change: stays on the incremental path, no rebuild.
	users = append(users, model.UserSpec{ID: 2, UUID: "22222222-2222-2222-2222-222222222222"})
	if err := s.Reload(ncA, users, kernel.TLSCert{}); err != nil {
		t.Fatalf("reload users: %v", err)
	}
	if s.box != firstBox {
		t.Fatal("user-only reload must not rebuild the box")
	}

	// Custom outbound change: must rebuild and actually take effect.
	ncB := testSocksNode(port, []model.OutboundConfig{socksOutbound("proxy-b", 1081)})
	if err := s.Reload(ncB, users, kernel.TLSCert{}); err != nil {
		t.Fatalf("reload outbounds: %v", err)
	}
	if s.box == firstBox {
		t.Fatal("outbound change must rebuild the box")
	}
	if !s.IsRunning() {
		t.Fatal("kernel must be running after rebuild")
	}
	tags := runningOutboundTags(t, s)
	if !tags["proxy-b"] {
		t.Fatalf("new outbound proxy-b was not applied: %v", tags)
	}
	if tags["proxy-a"] {
		t.Fatalf("stale outbound proxy-a is still present: %v", tags)
	}

	// Unchanged config: no rebuild.
	boxAfterRebuild := s.box
	if err := s.Reload(ncB, users, kernel.TLSCert{}); err != nil {
		t.Fatalf("reload unchanged config: %v", err)
	}
	if s.box != boxAfterRebuild {
		t.Fatal("unchanged config must not rebuild the box")
	}
}

// TestReloadRebuildsKernelWhenRoutesChange covers panel edits to custom routes.
func TestReloadRebuildsKernelWhenRoutesChange(t *testing.T) {
	port := freePort(t)
	users := []model.UserSpec{{ID: 1, UUID: "11111111-1111-1111-1111-111111111111"}}
	s := New(config.KernelConfig{Type: "sing-box", LogLevel: "info"})
	nc := testSocksNode(port, []model.OutboundConfig{socksOutbound("proxy-a", 1080)})
	if err := s.Start(nc, users, kernel.TLSCert{}); err != nil {
		t.Fatalf("start kernel: %v", err)
	}
	defer s.Stop()
	firstBox := s.box

	nc.CustomRouteRules = []model.CustomRouteRule{{
		Name:   "netflix-via-proxy-a",
		Match:  model.RouteMatch{DomainSuffixes: []string{".netflix.com"}},
		Action: model.RouteAction{Type: "route", Target: "proxy-a"},
	}}
	if err := s.Reload(nc, users, kernel.TLSCert{}); err != nil {
		t.Fatalf("reload routes: %v", err)
	}
	if s.box == firstBox {
		t.Fatal("route change must rebuild the box")
	}
	if !s.IsRunning() {
		t.Fatal("kernel must be running after route rebuild")
	}
}

// TestReloadRebuildRollsBackWhenNewConfigIsInvalid makes sure a bad panel edit
// cannot take the node offline: the previous config must be restored.
func TestReloadRebuildRollsBackWhenNewConfigIsInvalid(t *testing.T) {
	port := freePort(t)
	users := []model.UserSpec{{ID: 1, UUID: "11111111-1111-1111-1111-111111111111"}}
	s := New(config.KernelConfig{Type: "sing-box", LogLevel: "info"})
	ncGood := testSocksNode(port, []model.OutboundConfig{socksOutbound("proxy-a", 1080)})
	if err := s.Start(ncGood, users, kernel.TLSCert{}); err != nil {
		t.Fatalf("start kernel: %v", err)
	}
	defer s.Stop()

	ncBad := testSocksNode(port, []model.OutboundConfig{{Tag: "bad", Protocol: "not-a-real-protocol"}})
	err := s.Reload(ncBad, users, kernel.TLSCert{})
	if err == nil {
		t.Fatal("expected the rebuild to fail for an invalid outbound protocol")
	}
	if !s.IsRunning() {
		t.Fatalf("kernel must be restored after a failed rebuild (err=%v)", err)
	}
	if tags := runningOutboundTags(t, s); !tags["proxy-a"] {
		t.Fatalf("previous outbound table was not restored: %v", tags)
	}
}
