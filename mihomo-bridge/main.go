package main

/*
#include <stdlib.h>
*/
import "C"
import (
	"context"
	"encoding/json"
	"os"
	"sync"
	"time"
	"unsafe"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

var (
	mu        sync.Mutex
	isRunning bool
	tunFd     int
)

type ProxyInfo struct {
	Name    string `json:"name"`
	Type    string `json:"type"`
	Alive   bool   `json:"alive"`
	Latency int    `json:"latency"`
}

type GroupInfo struct {
	Name  string      `json:"name"`
	Type  string      `json:"type"`
	Now   string      `json:"now"`
	All   []string    `json:"all"`
	Nodes []ProxyInfo `json:"nodes"`
}

type TrafficInfo struct {
	UploadSpeed   int64 `json:"uploadSpeed"`
	DownloadSpeed int64 `json:"downloadSpeed"`
	UploadTotal   int64 `json:"uploadTotal"`
	DownloadTotal int64 `json:"downloadTotal"`
}

type ConnectionInfo struct {
	ID              string   `json:"id"`
	Host            string   `json:"host"`
	DestinationIP   string   `json:"destinationIP"`
	DestinationPort uint16   `json:"destinationPort"`
	SourceIP        string   `json:"sourceIP"`
	SourcePort      uint16   `json:"sourcePort"`
	Network         string   `json:"network"`
	ConnType        string   `json:"type"`
	Rule            string   `json:"rule"`
	RulePayload     string   `json:"rulePayload"`
	ProxyChain      []string `json:"proxyChain"`
	Upload          int64    `json:"uploadBytes"`
	Download        int64    `json:"downloadBytes"`
}

func returnJSON(v interface{}) *C.char {
	data, err := json.Marshal(v)
	if err != nil {
		fallback, _ := json.Marshal(map[string]string{"error": err.Error()})
		return C.CString(string(fallback))
	}
	return C.CString(string(data))
}

func returnStatus(status string) *C.char {
	return returnJSON(map[string]string{"status": status})
}

func returnError(message string) *C.char {
	return returnJSON(map[string]string{"error": message})
}

func normalizeDelay(delay uint16) int {
	if delay == 0 || delay >= 65535 {
		return -1
	}
	return int(delay)
}

//export ClashInit
func ClashInit(homeDirC *C.char) *C.char {
	if homeDirC == nil {
		return returnError("home dir is nil")
	}
	homeDir := C.GoString(homeDirC)
	if homeDir == "" {
		return returnError("home dir is empty")
	}
	if stat, err := os.Stat(homeDir); err != nil {
		return returnError("stat home dir: " + err.Error())
	} else if !stat.IsDir() {
		return returnError("home dir is not a directory")
	}
	constant.SetHomeDir(homeDir)
	return returnStatus("ok")
}

//export ClashStartFile
func ClashStartFile(configPathC *C.char) *C.char {
	mu.Lock()
	defer mu.Unlock()

	if isRunning {
		return returnError("already running")
	}

	if configPathC == nil {
		return returnError("config path is nil")
	}
	path := C.GoString(configPathC)
	if path == "" {
		return returnError("config path is empty")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return returnError("read file: " + err.Error())
	}

	return startBytes(data)
}

//export ClashStartContent
func ClashStartContent(configC *C.char) *C.char {
	mu.Lock()
	defer mu.Unlock()

	if isRunning {
		return returnError("already running")
	}

	if configC == nil {
		return returnError("config content is nil")
	}
	data := []byte(C.GoString(configC))
	if len(data) == 0 {
		return returnError("config content is empty")
	}

	return startBytes(data)
}

func startBytes(data []byte) *C.char {
	cfg, err := config.Parse(data)
	if err != nil {
		return returnError("parse config: " + err.Error())
	}

	// Inject TUN fd from VPN Extension
	if tunFd > 0 {
		cfg.General.Tun.Enable = true
		cfg.General.Tun.FileDescriptor = tunFd
		log.Infoln("ClashHM: injecting TUN fd=%d", tunFd)
	}

	cfg.Controller.ExternalController = "0.0.0.0:9090"
	cfg.Controller.Secret = ""

	hub.ApplyConfig(cfg)
	isRunning = true
	log.Infoln("ClashHM engine started")
	return returnStatus("ok")
}

//export ClashStop
func ClashStop() {
	mu.Lock()
	defer mu.Unlock()

	if !isRunning {
		return
	}

	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		c.Close()
		return true
	})

	isRunning = false
	log.Infoln("ClashHM engine stopped")
}

//export ClashIsRunning
func ClashIsRunning() C.int {
	if isRunning {
		return 1
	}
	return 0
}

//export ClashGetProxies
func ClashGetProxies() *C.char {
	proxies := tunnel.Proxies()
	var groups []GroupInfo

	for name, proxy := range proxies {
		adapter := proxy.Adapter()
		adapterType := adapter.Type().String()
		groupAdapter, ok := adapter.(outboundgroup.ProxyGroup)
		if !ok {
			continue
		}

		info := GroupInfo{
			Name: name,
			Type: adapterType,
			Now:  groupAdapter.Now(),
		}

		for _, nodeProxy := range groupAdapter.Proxies() {
			nodeName := nodeProxy.Name()
			info.All = append(info.All, nodeName)
			node := ProxyInfo{
				Name:    nodeName,
				Type:    nodeProxy.Adapter().Type().String(),
				Alive:   nodeProxy.AliveForTestUrl(""),
				Latency: normalizeDelay(nodeProxy.LastDelayForTestUrl("")),
			}
			info.Nodes = append(info.Nodes, node)
		}

		groups = append(groups, info)
	}

	if len(groups) == 0 {
		info := GroupInfo{
			Name: "Proxy",
			Type: "Selector",
		}
		for name, proxy := range proxies {
			adapter := proxy.Adapter()
			if _, ok := adapter.(outboundgroup.ProxyGroup); ok {
				continue
			}
			info.All = append(info.All, name)
			if info.Now == "" {
				info.Now = name
			}
			info.Nodes = append(info.Nodes, ProxyInfo{
				Name:    name,
				Type:    adapter.Type().String(),
				Alive:   proxy.AliveForTestUrl(""),
				Latency: normalizeDelay(proxy.LastDelayForTestUrl("")),
			})
		}
		if len(info.Nodes) > 0 {
			groups = append(groups, info)
		}
	}

	return returnJSON(groups)
}

//export ClashSelectProxy
func ClashSelectProxy(groupNameC *C.char, proxyNameC *C.char) C.int {
	groupName := C.GoString(groupNameC)
	proxyName := C.GoString(proxyNameC)

	proxies := tunnel.Proxies()
	proxy, ok := proxies[groupName]
	if !ok {
		return -1
	}

	if setter, ok := proxy.Adapter().(outboundgroup.SelectAble); ok {
		if err := setter.Set(proxyName); err != nil {
			return -2
		}
		return 0
	}
	return -3
}

//export ClashTestDelay
func ClashTestDelay(proxyNameC *C.char, urlC *C.char, timeoutC C.int) C.int {
	proxyName := C.GoString(proxyNameC)
	testURL := C.GoString(urlC)
	timeout := time.Duration(int(timeoutC)) * time.Millisecond

	if testURL == "" {
		testURL = "https://www.gstatic.com/generate_204"
	}
	if timeout == 0 {
		timeout = 5 * time.Second
	}

	proxies := tunnel.Proxies()
	proxy, ok := proxies[proxyName]
	if !ok {
		return -1
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	delay, err := proxy.URLTest(ctx, testURL, nil)
	if err != nil {
		return 0
	}
	return C.int(delay)
}

//export ClashGetTraffic
func ClashGetTraffic() *C.char {
	up, down := statistic.DefaultManager.Now()
	upTotal, downTotal := statistic.DefaultManager.Total()
	info := TrafficInfo{
		UploadSpeed:   up,
		DownloadSpeed: down,
		UploadTotal:   upTotal,
		DownloadTotal: downTotal,
	}
	return returnJSON(info)
}

//export ClashGetConnections
func ClashGetConnections() *C.char {
	snap := statistic.DefaultManager.Snapshot()
	var conns []ConnectionInfo

	for _, c := range snap.Connections {
		meta := c.Metadata
		var chains []string
		for _, ch := range c.Chain {
			chains = append(chains, ch)
		}

		conn := ConnectionInfo{
			ID:              c.UUID.String(),
			Host:            meta.Host,
			DestinationIP:   meta.DstIP.String(),
			DestinationPort: meta.DstPort,
			SourceIP:        meta.SrcIP.String(),
			SourcePort:      meta.SrcPort,
			Network:         meta.NetWork.String(),
			ConnType:        meta.Type.String(),
			Rule:            c.Rule,
			RulePayload:     c.RulePayload,
			ProxyChain:      chains,
			Upload:          c.UploadTotal.Load(),
			Download:        c.DownloadTotal.Load(),
		}
		conns = append(conns, conn)
	}

	return returnJSON(conns)
}

//export ClashCloseAllConnections
func ClashCloseAllConnections() {
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		c.Close()
		return true
	})
}

//export ClashCloseConnection
func ClashCloseConnection(idC *C.char) {
	id := C.GoString(idC)
	if c := statistic.DefaultManager.Get(id); c != nil {
		c.Close()
	}
}

//export ClashGetMode
func ClashGetMode() *C.char {
	return C.CString(tunnel.Mode().String())
}

//export ClashSetMode
func ClashSetMode(modeC *C.char) {
	modeStr := C.GoString(modeC)
	mode, ok := tunnel.ModeMapping[modeStr]
	if !ok {
		mode = tunnel.Rule
	}
	tunnel.SetMode(mode)
}

//export ClashSetTunFd
func ClashSetTunFd(fd C.int) {
	tunFd = int(fd)
	log.Infoln("ClashHM: TUN fd stored: %d", tunFd)
}

//export ClashFreeString
func ClashFreeString(p *C.char) {
	C.free(unsafe.Pointer(p))
}

func main() {}
