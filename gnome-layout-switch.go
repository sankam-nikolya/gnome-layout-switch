//go:generate env CGO_ENABLED=0 go build -o ./gnome-layout-switch -ldflags "-s -w"

// Package main implements gnome-layout-switch, a lightweight daemon that switches
// GNOME keyboard layout on a configurable key combination (default: Ctrl+Shift).
// It works on both X11 and Wayland (GNOME 45–51+, including Ubuntu 26) via a
// bundled GNOME Shell Extension that exports D-Bus Next() / Previous() / GetCurrent().
//
// On Wayland, it reads directly from /dev/input/eventX devices (requires user to be
// in the 'input' group). On X11, it uses xinput test-xi2.
//
// The daemon can be run manually or installed as a systemd user service for automatic
// startup on graphical login.
//
// Configuration is stored in ~/.config/gnome-layout-switch/config.json and can
// be managed via CLI flags or the -save-config flag.
package main

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
)

const (
	appName    = "gnome-layout-switch"
	appVersion = "1.4.1"

	// Own extension D-Bus names.
	extDest       = "org.gnome.Shell"
	extObjectPath = "/org/gnome/Shell/Extensions/GnomeLayoutSwitch"
	extIface      = "org.gnome.Shell.Extensions.GnomeLayoutSwitch"
	extUUID       = "gnome-layout-switch@gnome-layout-switch"

	// X11 keycodes (xinput test-xi2 / xev).
	x11Key1Default = "37,105" // Left/Right Ctrl
	x11Key2Default = "50,62"  // Left/Right Shift

	// Linux EV_KEY codes (input-event-codes.h) — required for /dev/input/eventX (Wayland).
	linuxKey1Default = "29,97" // KEY_LEFTCTRL, KEY_RIGHTCTRL
	linuxKey2Default = "42,54" // KEY_LEFTSHIFT, KEY_RIGHTSHIFT
)

// EventData represents a parsed xinput event from xinput test-xi2.
// Type is the event type (e.g., "RawKeyPress", "RawKeyRelease").
// Detail is the keycode as uint16.
type EventData struct {
	Type   string
	Detail uint16
}

// Config holds the application configuration.
// Key1 and Key2 are comma-separated keycodes for the trigger combination.
// Input is the /dev/input/eventX path (required on Wayland).
// Debug enables verbose logging.
// Device is an optional name filter for auto-detection.
type Config struct {
	Key1   string `json:"key1"`  // comma-separated keycodes
	Key2   string `json:"key2"`  // comma-separated keycodes
	Input  string `json:"input"` // /dev/input/eventX (required on Wayland)
	Debug  bool   `json:"debug"`
	Device string `json:"device"` // optional friendly name filter for auto-detect
}

var (
	cfg     Config
	key1Set = make(map[uint16]struct{})
	key2Set = make(map[uint16]struct{})

	key1Pressed = false
	key2Pressed = false
	canSwitch   = false

	// gdbus command templates for reuse.
	extNextCmdTmpl *exec.Cmd
	extPrevCmdTmpl *exec.Cmd
	extGetCmdTmpl  *exec.Cmd
)

// defaultConfigPath returns the default configuration file path.
// Uses XDG_CONFIG_HOME if set, otherwise ~/.config/gnome-layout-switch/config.json.
func defaultConfigPath() string {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, appName, "config.json")
	}

	home, _ := os.UserHomeDir()

	return filepath.Join(home, ".config", appName, "config.json")
}

// loadConfig reads and parses the JSON configuration file at path.
// Populates the global cfg variable. Returns error if file does not exist or JSON is invalid.
func loadConfig(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}

	return json.Unmarshal(data, &cfg)
}

// saveConfig writes the current configuration to path as indented JSON.
// Creates parent directories if needed (0755). File permissions 0644.
func saveConfig(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(path, data, 0o644)
}

func dumpEvent(event *EventData) {
	if cfg.Debug {
		log.Printf("EVENT: %+v", event)
	}
}

// isWayland detects if the current session is Wayland.
// Checks XDG_SESSION_TYPE first, then falls back to WAYLAND_DISPLAY env var.
func isWayland() bool {
	if t := os.Getenv("XDG_SESSION_TYPE"); t != "" {
		return strings.EqualFold(t, "wayland")
	}

	return os.Getenv("WAYLAND_DISPLAY") != ""
}

// initGdbusTemplates creates and caches gdbus command templates at startup
// to avoid allocation overhead on each layout switch.
func initGdbusTemplates() {
	baseArgs := []string{"call", "--session", "--dest", extDest}

	// Own extension: Next / Previous / GetCurrent
	extNextCmdTmpl = exec.Command("gdbus", append(baseArgs,
		"--object-path", extObjectPath,
		"--method", extIface+".Next")...)
	extPrevCmdTmpl = exec.Command("gdbus", append(baseArgs,
		"--object-path", extObjectPath,
		"--method", extIface+".Previous")...)
	extGetCmdTmpl = exec.Command("gdbus", append(baseArgs,
		"--object-path", extObjectPath,
		"--method", extIface+".GetCurrent")...)
}

// switchLayout switches the GNOME keyboard layout via the bundled Shell extension.
// Logs an error with installation hints if the D-Bus call fails.
func switchLayout() {
	if cfg.Debug {
		log.Println(">>> Switching layout")
	}

	if tryExtensionNext() {
		return
	}

	log.Println("Unable to switch layout: extension not available." +
		"\nInstall and enable the bundled extension:" +
		"\n  gnome-extensions enable " + extUUID +
		"\n  (or re-run ./install.sh)" +
		"\nOn Wayland, log out and back in after enabling the extension.")
}

// tryExtensionNext calls the own extension's Next() method via D-Bus.
// Returns true if the call succeeded (layout was switched).
func tryExtensionNext() bool {
	out, err := runGdbus(extNextCmdTmpl)
	if err != nil {
		if cfg.Debug {
			log.Printf("Own extension Next() failed: %v", err)
		}

		return false
	}

	if cfg.Debug {
		log.Printf("Own extension Next() OK: %s", strings.TrimSpace(string(out)))
	}

	return true
}

// runGdbus executes a gdbus template and returns combined output.
func runGdbus(tmpl *exec.Cmd, extraArgs ...string) ([]byte, error) {
	cmd := *tmpl

	cmd.Args = append([]string{}, tmpl.Args...)
	if len(extraArgs) > 0 {
		cmd.Args = append(cmd.Args, extraArgs...)
	}

	if cfg.Debug {
		log.Printf("Trying: %s", strings.Join(cmd.Args, " "))
	}

	return cmd.CombinedOutput()
}

// checkExtension reports whether the own GNOME Shell extension is available
// and prints diagnostic information. Used by -check flag and at startup.
func checkExtension() (ok bool, detail string) {
	// 1. Is the extension known to gnome-extensions?
	out, err := exec.Command("gnome-extensions", "info", extUUID).CombinedOutput()
	info := strings.TrimSpace(string(out))

	if err != nil {
		return false, fmt.Sprintf("extension %s not installed (gnome-extensions info failed: %v)", extUUID, err)
	}

	enabled := strings.Contains(strings.ToLower(info), "state: enabled") ||
		strings.Contains(info, "ENABLED")
	if !enabled {
		return false, fmt.Sprintf("extension %s installed but not enabled:\n%s\nRun: gnome-extensions enable %s", extUUID, info, extUUID)
	}

	// 2. Can we call GetCurrent() on the session bus?
	out, err = runGdbus(extGetCmdTmpl)
	if err != nil {
		return false, fmt.Sprintf("extension enabled but D-Bus call failed: %v\nOutput: %s\nCheck `gnome-extensions info %s`; on Wayland, log out and back in after enabling.", err, strings.TrimSpace(string(out)), extUUID)
	}

	return true, fmt.Sprintf("extension OK (GetCurrent → %s)", strings.TrimSpace(string(out)))
}

// processEvent handles xinput events for the X11 mode.
// Tracks key press/release state for the two configured keys and triggers
// switchLayout() when both keys are pressed together (chord detection).
func processEvent(event *EventData) {
	if event.Type == "" {
		return
	}

	if event.Type == "RawKeyPress" {
		dumpEvent(event)

		if _, ok := key1Set[event.Detail]; ok {
			key1Pressed = true
			canSwitch = key2Pressed

			return
		}

		if _, ok := key2Set[event.Detail]; ok {
			key2Pressed = true
			canSwitch = key1Pressed

			return
		}

		canSwitch = false
	}

	if event.Type == "RawKeyRelease" {
		dumpEvent(event)

		doSwitch := false

		if _, ok := key1Set[event.Detail]; ok {
			if key2Pressed {
				doSwitch = true
			}

			key1Pressed = false
		}

		if _, ok := key2Set[event.Detail]; ok {
			if key1Pressed {
				doSwitch = true
			}

			key2Pressed = false
		}

		if canSwitch && doSwitch {
			switchLayout()
		}
	}
}

const (
	EvTypeKey      = 1
	EvValueKeyDown = 1
	EvValueKeyUp   = 0
)

// InputEvent represents a raw Linux input event from /dev/input/eventX.
// Matches the struct layout of struct input_event from linux/input.h (20 bytes total).
// Layout on Ubuntu's standard 64-bit x86_64/aarch64 ABI:
// timeval (sec int64 + usec int64) + type (uint16) + code (uint16) + value (int32) = 24 bytes.
// Using uint32 for Usec incorrectly made the record 20 bytes and desynchronized
// every subsequent event on 64-bit systems.
type InputEvent struct {
	Sec   int64
	Usec  int64
	Type  uint16
	Code  uint16
	Value int32
}

// directEvent opens the first openable device from paths and reads events in a loop.
// Sets up signal handling for clean shutdown (SIGINT, SIGTERM).
// Parses InputEvent structs and delegates to processDirectEvent for key events.
// Exits fatally if no device can be opened or on read errors (except EOF).
func directEvent(paths []string) {
	var (
		file    *os.File
		err     error
		lastErr error
	)

	for _, path := range paths {
		var f *os.File

		f, err = os.Open(path)
		if err == nil {
			file = f

			if len(paths) > 1 {
				log.Printf("Using input device: %s", path)
			}

			break
		}

		lastErr = err
	}

	if file == nil {
		log.Fatalf("Cannot open any of %v: %v\n"+
			"Add user to 'input' group:\n"+
			"  sudo usermod -aG input $USER\n"+
			"Then log out and back in.", paths, lastErr)
	}

	defer file.Close()

	// Handle signals for clean shutdown
	sigCh := make(chan os.Signal, 1)

	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Println("Shutting down...")
		os.Exit(0)
	}()

	event := InputEvent{}
	for {
		err = binary.Read(file, binary.LittleEndian, &event)
		if err != nil {
			if errors.Is(err, io.EOF) {
				log.Println("Input device closed (EOF).")
				return
			}

			log.Fatal(err)
		}

		if event.Type == EvTypeKey && (event.Value == EvValueKeyDown || event.Value == EvValueKeyUp) {
			if cfg.Debug {
				tp := "Up"
				if event.Value == EvValueKeyDown {
					tp = "Down"
				}

				log.Printf("Key Code: %d %s", event.Code, tp)
			}

			processDirectEvent(event)
		}
	}
}

// processDirectEvent handles raw Linux input events for the Wayland mode.
// Similar to processEvent but works with InputEvent from /dev/input/eventX.
// Uses direct uint16 keycode lookup.
func processDirectEvent(event InputEvent) {
	keycode := event.Code

	if event.Value == EvValueKeyDown {
		if _, ok := key1Set[keycode]; ok {
			key1Pressed = true
			canSwitch = key2Pressed

			return
		}

		if _, ok := key2Set[keycode]; ok {
			key2Pressed = true
			canSwitch = key1Pressed

			return
		}

		canSwitch = false
	}

	if event.Value == EvValueKeyUp {
		doSwitch := false

		if _, ok := key1Set[keycode]; ok {
			if key2Pressed {
				doSwitch = true
			}

			key1Pressed = false
		}

		if _, ok := key2Set[keycode]; ok {
			if key1Pressed {
				doSwitch = true
			}

			key2Pressed = false
		}

		if canSwitch && doSwitch {
			switchLayout()
		}
	}
}

// parseXInputEvents parses both standard multi-line XI2 events and the
// compact one-line form used by some xinput versions/wrappers.
func parseXInputEvents(r io.Reader, handle func(*EventData)) {
	reCompact := regexp.MustCompile(`^EVENT\s+(RawKeyPress|RawKeyRelease)\s+detail:\s*(\d+)`)
	reHeader := regexp.MustCompile(`^EVENT\s+type\s+\d+\s+\((RawKeyPress|RawKeyRelease)\)`)
	reDetail := regexp.MustCompile(`^detail:\s*(\d+)`)
	scanner := bufio.NewScanner(r)
	currentType := ""
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if m := reCompact.FindStringSubmatch(line); m != nil {
			if n, err := strconv.ParseUint(m[2], 10, 16); err == nil {
				handle(&EventData{Type: m[1], Detail: uint16(n)})
			}
			currentType = ""
			continue
		}
		if m := reHeader.FindStringSubmatch(line); m != nil {
			currentType = m[1]
			continue
		}
		if currentType != "" {
			if m := reDetail.FindStringSubmatch(line); m != nil {
				if n, err := strconv.ParseUint(m[1], 10, 16); err == nil {
					handle(&EventData{Type: currentType, Detail: uint16(n)})
				}
				currentType = ""
			}
		}
	}
}

// xinputMode runs the X11 event loop using xinput test-xi2 --root.
// Parses xinput output in a goroutine, delegates events to processEvent.
// Sets up signal handling for clean shutdown.
//
// xinput test-xi2 emits multi-line XI2 events; parseXInputEvents also
// accepts the compact one-line format emitted by some versions/wrappers.
func xinputMode() {
	cmd := exec.Command("xinput", "test-xi2", "--root")
	reader, writer := io.Pipe()
	cmd.Stdout = writer

	go func() {
		parseXInputEvents(reader, processEvent)
	}()

	// Handle signals
	sigCh := make(chan os.Signal, 1)

	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Println("Shutting down...")

		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}

		os.Exit(0)
	}()

	err := cmd.Run()
	_ = writer.Close()
	_ = reader.Close()

	if err != nil {
		log.Fatalf("Unable to run xinput: %v (check that xinput is installed and DISPLAY/XAUTHORITY are available)", err)
	}
}

// inputDevice describes one block of /proc/bus/input/devices.
type inputDevice struct {
	name     string // N: Name=...
	handlers string // H: Handlers=...
	ev       uint64 // B: EV= bitmask (hex), 0 if absent
}

// parseInputDevices parses /proc/bus/input/devices blocks into inputDevice values.
func parseInputDevices(r io.Reader) []inputDevice {
	var devices []inputDevice

	scanner := bufio.NewScanner(r)

	var cur inputDevice

	flush := func() {
		if cur.name != "" {
			devices = append(devices, cur)
		}

		cur = inputDevice{}
	}

	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case line == "":
			flush()
		case strings.HasPrefix(line, "N: Name="):
			cur.name = strings.Trim(strings.TrimPrefix(line, "N: Name="), `"`)
		case strings.HasPrefix(line, "H: Handlers="):
			cur.handlers = strings.TrimPrefix(line, "H: Handlers=")
		case strings.HasPrefix(line, "B: EV="):
			if v, err := strconv.ParseUint(strings.TrimPrefix(line, "B: EV="), 16, 64); err == nil {
				cur.ev = v
			}
		}
	}

	flush()

	return devices
}

// nonKeyboardNameFragments are device name fragments that identify hardware
// which is not a usable keyboard (buttons, mice, lid switches, hotkeys, ...).
var nonKeyboardNameFragments = []string{
	"power", "sleep", "mouse", "touchpad", "lid", "video",
	"wmi", "hotkey", "audio", "mic", "headphone",
}

// findKeyboardEvents auto-detects keyboard /dev/input/eventX devices.
// Parses /proc/bus/input/devices and returns candidate device paths in
// preference order: real keyboards first (name contains "keyboard"), then
// full keyboards (EV mask with EV_MSC bit, typical 0x120013/0x12001f),
// then any remaining KEY-capable device.
// Devices whose names match non-keyboard hardware are skipped.
// Optional nameFilter (case-insensitive) restricts candidates by name.
func findKeyboardEvents(nameFilter string) []string {
	f, err := os.Open("/proc/bus/input/devices")
	if err != nil {
		return nil
	}
	defer f.Close()

	return selectKeyboardDevices(parseInputDevices(f), nameFilter)
}

// selectKeyboardDevices picks and ranks inputDevice values into device paths.
func selectKeyboardDevices(devices []inputDevice, nameFilter string) []string {
	lowerFilter := strings.ToLower(nameFilter)
	excluded := func(name string) bool {
		n := strings.ToLower(name)
		for _, bad := range nonKeyboardNameFragments {
			if strings.Contains(n, bad) {
				return true
			}
		}

		return false
	}

	type candidate struct {
		path string
		name string
		rank int // lower = better
	}

	var candidates []candidate

	for _, d := range devices {
		if !strings.Contains(d.handlers, "event") {
			continue
		}

		if d.ev&1 == 0 { // no EV_KEY capability
			continue
		}

		name := strings.ToLower(d.name)
		if nameFilter != "" && !strings.Contains(name, lowerFilter) {
			continue
		}

		if excluded(d.name) {
			continue
		}

		rank := 2
		if strings.Contains(name, "keyboard") {
			rank = 0
		} else if d.ev&0x10000 != 0 { // EV_MSC bit — typical full keyboards
			rank = 1
		}

		for part := range strings.FieldsSeq(d.handlers) {
			if strings.HasPrefix(part, "event") {
				candidates = append(candidates, candidate{path: "/dev/input/" + part, name: d.name, rank: rank})
				break
			}
		}
	}

	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].rank < candidates[j].rank })

	var paths []string
	for _, c := range candidates {
		paths = append(paths, c.path)
		if cfg.Debug {
			log.Printf("Keyboard candidate: %s (%s)", c.path, c.name)
		}
	}

	return paths
}

// installService creates a systemd user service unit file.
// Uses the current binary path and configuration to build ExecStart.
// Writes to ~/.config/systemd/user/gnome-layout-switch.service.
// Prints instructions for enabling and starting the service.
//
// On Wayland (or when an explicit --input is set) the unit includes
// --auto-input / --input so the daemon reads /dev/input/event*.
// On X11 the unit starts the binary with no input flags so it uses
// xinput test-xi2 and does not require membership in the input group.
func installService() {
	exe, err := os.Executable()
	if err != nil {
		log.Fatal(err)
	}

	exe, _ = filepath.Abs(exe)

	home, _ := os.UserHomeDir()

	unitDir := filepath.Join(home, ".config", "systemd", "user")
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		log.Fatal(err)
	}

	unitPath := filepath.Join(unitDir, appName+".service")

	args := []string{exe}
	wayland := isWayland()

	if cfg.Input != "" {
		args = append(args, "--input", cfg.Input)
	} else if wayland {
		// Wayland needs /dev/input; X11 must not force --auto-input
		// (that path requires the input group and fails with permission denied).
		args = append(args, "--auto-input")
	}

	if cfg.Device != "" {
		args = append(args, "--device", cfg.Device)
	}

	if cfg.Key1 != x11Key1Default && cfg.Key1 != linuxKey1Default {
		args = append(args, "--key1", cfg.Key1)
	}

	if cfg.Key2 != x11Key2Default && cfg.Key2 != linuxKey2Default {
		args = append(args, "--key2", cfg.Key2)
	}

	if cfg.Debug {
		args = append(args, "--debug")
	}

	unit := fmt.Sprintf(`[Unit]
Description=GNOME Keyboard Layout Switcher (Ctrl+Shift)
Documentation=https://github.com/sankam-nikolya/gnome-layout-switch
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=%s
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
`, strings.Join(args, " "))

	if err := os.WriteFile(unitPath, []byte(unit), 0o644); err != nil {
		log.Fatal(err)
	}

	fmt.Printf("Service unit written to:\n  %s\n\n", unitPath)
	fmt.Printf("Session detected: %s\n", map[bool]string{true: "Wayland", false: "X11"}[wayland])
	fmt.Printf("ExecStart: %s\n\n", strings.Join(args, " "))
	fmt.Println("Enable and start it with:")
	fmt.Println("  systemctl --user daemon-reload")
	fmt.Println("  systemctl --user enable --now " + appName + ".service")
	fmt.Println()
	fmt.Println("Check status:")
	fmt.Println("  systemctl --user status " + appName + ".service")
	if wayland {
		fmt.Println()
		fmt.Println("Important on Wayland:")
		fmt.Println("  sudo usermod -aG input $USER")
		fmt.Println("  (then log out and back in)")
	}
}

func printVersion() {
	fmt.Printf("%s %s\n", appName, appVersion)
}

func printHelp() {
	fmt.Printf(`%s %s — GNOME keyboard layout switcher (Ctrl+Shift)

USAGE:
  %s [OPTIONS]

DESCRIPTION:
  Listens for a key combination (default: Ctrl + Shift) and switches
  the GNOME input source via a bundled GNOME Shell extension.
  Works on X11 and Wayland (Ubuntu 26 / GNOME 45–51).

OPTIONS:
  -h, -help              Show help and exit
  -version               Show version and exit
  -check                 Check extension availability and exit

  -key1 string           First key codes, comma-separated
                         X11 default: "37,105" (Ctrl); Wayland: "29,97"
  -key2 string           Second key codes, comma-separated
                         X11 default: "50,62" (Shift); Wayland: "42,54"
  -input string          Path to /dev/input/eventX
                         Required on Wayland (or use -auto-input)
  -auto-input            Auto-detect keyboard event device
  -device string         Name filter for -auto-input
                         (e.g. "AT Translated", "Logitech")
  -debug                 Enable verbose logging

  -config string         Path to config.json
                         (default: ~/.config/%s/config.json)
  -save-config           Save current flags to config file and exit
  -install-service       Install systemd user service and exit

EXAMPLES:
  # X11 (uses xinput)
  %s

  # Wayland — auto-detect keyboard
  %s -auto-input

  # Wayland — explicit device
  %s -input /dev/input/event3

  # Check extension status
  %s -check

  # Custom keys + save config
  %s -key1 37,105 -key2 64 -auto-input -save-config

  # Install as user service
  %s -install-service
  systemctl --user enable --now %s.service

WAYLAND NOTES:
  sudo usermod -aG input $USER   # then log out / log in

  Find devices:
    cat /proc/bus/input/devices | grep -A 10 -i keyboard
    libinput list-devices

EXTENSION (required for layout switching):
  Bundled: gnome-layout-switch@gnome-layout-switch
  Enable:  gnome-extensions enable %s
  (install.sh installs and enables it automatically)

`, appName, appVersion, appName, appName,
		appName, appName, appName, appName, appName, appName, appName, extUUID)
}

func main() {
	flag.Usage = printHelp

	var (
		showVersion  = flag.Bool("version", false, "Show version")
		checkExt     = flag.Bool("check", false, "Check extension availability and exit")
		configPath   = flag.String("config", "", "Path to config.json (default: ~/.config/"+appName+"/config.json)")
		saveCfg      = flag.Bool("save-config", false, "Save current flags to config file and exit")
		installSvc   = flag.Bool("install-service", false, "Install systemd user service and exit")
		autoDetect   = flag.Bool("auto-input", false, "Auto-detect keyboard event device (Wayland)")
		deviceFilter = flag.String("device", "", "Name filter for --auto-input (e.g. 'AT Translated')")
	)

	cfg.Key1 = x11Key1Default
	cfg.Key2 = x11Key2Default
	cfg.Debug = false

	flagKey1 := flag.String("key1", "", "First key codes, comma-separated (default: 37,105 [Ctrl])")
	flagKey2 := flag.String("key2", "", "Second key codes, comma-separated (default: 50,62 [Shift])")
	flagInput := flag.String("input", "", "Direct input device (/dev/input/eventX) — required on Wayland")
	flagDebug := flag.Bool("debug", false, "Enable debug logging")

	flag.Parse()

	if *showVersion {
		printVersion()
		return
	}

	initGdbusTemplates()

	if *checkExt {
		ok, detail := checkExtension()
		if ok {
			fmt.Printf("PASS: %s\n", detail)
			os.Exit(0)
		}

		fmt.Printf("FAIL: %s\n", detail)
		os.Exit(1)
	}

	cfgFile := *configPath
	if cfgFile == "" {
		cfgFile = defaultConfigPath()
	}

	if err := loadConfig(cfgFile); err == nil {
		if cfg.Debug {
			log.Printf("Loaded config from %s", cfgFile)
		}
	}

	if *flagKey1 != "" {
		cfg.Key1 = *flagKey1
	}

	if *flagKey2 != "" {
		cfg.Key2 = *flagKey2
	}

	if *flagInput != "" {
		cfg.Input = *flagInput
	}

	if *flagDebug {
		cfg.Debug = true
	}

	if *deviceFilter != "" {
		cfg.Device = *deviceFilter
	}

	key1Codes := strings.Split(cfg.Key1, ",")
	key2Codes := strings.Split(cfg.Key2, ",")
	key1Set = make(map[uint16]struct{}, len(key1Codes))
	key2Set = make(map[uint16]struct{}, len(key2Codes))

	for _, k := range key1Codes {
		k = strings.TrimSpace(k)
		if k != "" {
			if keycode, err := strconv.ParseUint(k, 10, 16); err == nil {
				key1Set[uint16(keycode)] = struct{}{}
			}
		}
	}

	for _, k := range key2Codes {
		k = strings.TrimSpace(k)
		if k != "" {
			if keycode, err := strconv.ParseUint(k, 10, 16); err == nil {
				key2Set[uint16(keycode)] = struct{}{}
			}
		}
	}

	if *saveCfg {
		if err := saveConfig(cfgFile); err != nil {
			log.Fatal(err)
		}

		fmt.Printf("Config saved to %s\n", cfgFile)

		return
	}

	if *installSvc {
		installService()
		return
	}

	wayland := isWayland()

	var inputPaths []string
	if cfg.Input != "" {
		inputPaths = []string{cfg.Input}
	} else if wayland || *autoDetect {
		inputPaths = findKeyboardEvents(cfg.Device)
		if len(inputPaths) > 0 && (cfg.Debug || *autoDetect) {
			log.Printf("Auto-detected keyboard(s): %s", strings.Join(inputPaths, ", "))
		}
		// Set before the X11→Linux keycode remapping below.
		if cfg.Input == "" && len(inputPaths) > 0 {
			cfg.Input = inputPaths[0]
		}
	}

	// Direct /dev/input (Wayland) uses Linux EV_KEY codes, not X11 keycodes.
	// If the user still has the X11 defaults (or empty), switch to Linux defaults.
	if cfg.Input != "" {
		if cfg.Key1 == "" || cfg.Key1 == x11Key1Default {
			cfg.Key1 = linuxKey1Default
			key1Set = make(map[uint16]struct{})

			for k := range strings.SplitSeq(cfg.Key1, ",") {
				k = strings.TrimSpace(k)
				if k != "" {
					if keycode, err := strconv.ParseUint(k, 10, 16); err == nil {
						key1Set[uint16(keycode)] = struct{}{}
					}
				}
			}
		}

		if cfg.Key2 == "" || cfg.Key2 == x11Key2Default {
			cfg.Key2 = linuxKey2Default
			key2Set = make(map[uint16]struct{})

			for k := range strings.SplitSeq(cfg.Key2, ",") {
				k = strings.TrimSpace(k)
				if k != "" {
					if keycode, err := strconv.ParseUint(k, 10, 16); err == nil {
						key2Set[uint16(keycode)] = struct{}{}
					}
				}
			}
		}
	}

	if cfg.Debug {
		if wayland {
			log.Println("Session: Wayland")
		} else {
			log.Println("Session: X11")
		}

		log.Printf("Key1=%s  Key2=%s  Input=%s", cfg.Key1, cfg.Key2, cfg.Input)
	}

	// Soft diagnostics for the primary backend (own extension).
	if ok, detail := checkExtension(); ok {
		if cfg.Debug {
			log.Printf("Backend: %s", detail)
		}
	} else {
		log.Printf("WARNING: primary layout backend unavailable: %s", detail)
	}

	if len(inputPaths) > 0 {
		directEvent(inputPaths)
		return
	}

	if wayland {
		log.Fatal("On Wayland you must specify a keyboard device.\n\n" +
			"Options:\n" +
			"  1. Manual:  --input /dev/input/eventX\n" +
			"  2. Auto:    --auto-input\n" +
			"  3. Filter:  --auto-input --device \"AT Translated\"\n\n" +
			"Find devices:\n" +
			"  cat /proc/bus/input/devices | grep -A 10 -i keyboard\n" +
			"  libinput list-devices\n\n" +
			"Add user to input group:\n" +
			"  sudo usermod -aG input $USER && loginctl terminate-user $USER")
	}

	xinputMode()
}
