package main

import (
	"bytes"
	"encoding/binary"
	"strconv"
	"strings"
	"testing"
)

func BenchmarkKeycodeLookupStringMap(b *testing.B) {
	keySet := make(map[string]struct{}, 10)
	for _, k := range []string{"37", "105", "50", "62"} {
		keySet[k] = struct{}{}
	}

	keycode := "37"

	b.ResetTimer()

	for range b.N {
		_, _ = keySet[keycode]
	}
}

func BenchmarkKeycodeLookupUint16Map(b *testing.B) {
	keySet := make(map[uint16]struct{}, 10)
	for _, k := range []uint16{37, 105, 50, 62} {
		keySet[k] = struct{}{}
	}

	keycode := uint16(37)

	b.ResetTimer()

	for range b.N {
		_, _ = keySet[keycode]
	}
}

func BenchmarkKeycodeStringConversion(b *testing.B) {
	keycode := uint16(37)

	b.ResetTimer()

	for range b.N {
		_ = strconv.Itoa(int(keycode))
	}
}

func BenchmarkConfigParsingString(b *testing.B) {
	key1 := "37,105"
	key2 := "50,62"
	key1Set := make(map[string]struct{})
	key2Set := make(map[string]struct{})

	b.ResetTimer()

	for range b.N {
		for _, k := range splitAndTrim(key1) {
			if k != "" {
				key1Set[k] = struct{}{}
			}
		}

		for _, k := range splitAndTrim(key2) {
			if k != "" {
				key2Set[k] = struct{}{}
			}
		}
	}
}

func BenchmarkConfigParsingUint16(b *testing.B) {
	key1 := "37,105"
	key2 := "50,62"
	key1Set := make(map[uint16]struct{})
	key2Set := make(map[uint16]struct{})

	b.ResetTimer()

	for range b.N {
		for _, k := range splitAndTrim(key1) {
			if k != "" {
				if keycode, err := strconv.ParseUint(k, 10, 16); err == nil {
					key1Set[uint16(keycode)] = struct{}{}
				}
			}
		}

		for _, k := range splitAndTrim(key2) {
			if k != "" {
				if keycode, err := strconv.ParseUint(k, 10, 16); err == nil {
					key2Set[uint16(keycode)] = struct{}{}
				}
			}
		}
	}
}

func BenchmarkProcessDirectEvent(b *testing.B) {
	// Setup global state for benchmark
	key1Set = make(map[uint16]struct{})
	key2Set = make(map[uint16]struct{})
	key1Set[37] = struct{}{}
	key2Set[50] = struct{}{}
	key1Pressed = false
	key2Pressed = false
	canSwitch = false

	event := InputEvent{
		Type:  EvTypeKey,
		Code:  37,
		Value: EvValueKeyDown,
	}

	b.ResetTimer()

	for range b.N {
		processDirectEvent(event)
	}
}

func BenchmarkProcessEvent(b *testing.B) {
	key1Set = make(map[uint16]struct{})
	key2Set = make(map[uint16]struct{})
	key1Set[37] = struct{}{}
	key2Set[50] = struct{}{}
	key1Pressed = false
	key2Pressed = false
	canSwitch = false

	event := &EventData{
		Type:   "RawKeyPress",
		Detail: 37,
	}

	b.ResetTimer()

	for range b.N {
		processEvent(event)
	}
}

func splitAndTrim(s string) []string {
	parts := []string{}

	for _, k := range splitComma(s) {
		k = trimSpace(k)
		if k != "" {
			parts = append(parts, k)
		}
	}

	return parts
}

func splitComma(s string) []string {
	var parts []string

	start := 0

	for i := range len(s) {
		if s[i] == ',' {
			parts = append(parts, s[start:i])
			start = i + 1
		}
	}

	parts = append(parts, s[start:])

	return parts
}

func trimSpace(s string) string {
	start := 0

	end := len(s)
	for start < end && (s[start] == ' ' || s[start] == '\t' || s[start] == '\n' || s[start] == '\r') {
		start++
	}

	for end > start && (s[end-1] == ' ' || s[end-1] == '\t' || s[end-1] == '\n' || s[end-1] == '\r') {
		end--
	}

	return s[start:end]
}

const procBusInputDevicesSample = `I: Bus=0019 Vendor=0000 Product=0001 Version=0000
N: Name="Power Button"
P: Phys=PNP0C0C/button/input0
H: Handlers=kbd event0
B: PROP=0
B: EV=3
B: KEY=8000 10000000000000 0

I: Bus=0003 Vendor=3044 Product=30b1 Version=0111
N: Name="Telink MIIIW 2.4G Mouse Consumer Control"
H: Handlers=kbd event4
B: EV=1f
B: KEY=733eff 0 0 483ffff17aff32d

I: Bus=0009 Vendor=0001 Vendor=8910 Version=0000
N: Name="ITE Tech. Inc. ITE Device(8910)"
H: Handlers=sysrq rfkill kbd mouse3 event10 leds
B: EV=12001f
B: KEY= 40000 0 0 0 0

I: Bus=001d Vendor=0000 Product=0001 Version=0000
N: Name="Asus WMI hotkeys"
H: Handlers=rfkill kbd event11
B: EV=100013
B: KEY= 40000 0 0 0 0
`

const procBusInputDevicesKeyboardNamed = `I: Bus=0019 Vendor=0000 Product=0001 Version=0000
N: Name="Power Button"
H: Handlers=kbd event0
B: EV=3
B: KEY=8000 10000000000000 0

I: Bus=0009 Vendor=0001 Vendor=8910 Version=0000
N: Name="ASUS Keyboard"
H: Handlers=kbd event20
B: EV=120013
B: KEY= 40000 0 0 0 0

I: Bus=0009 Vendor=0001 Vendor=8910 Version=0000
N: Name="ITE Tech. Inc. ITE Device(8910)"
H: Handlers=sysrq rfkill kbd mouse3 event10 leds
B: EV=12001f
B: KEY= 40000 0 0 0 0
`

func TestSelectKeyboardDevicesPrefersRealKeyboard(t *testing.T) {
	devices := parseInputDevices(strings.NewReader(procBusInputDevicesSample))

	got := selectKeyboardDevices(devices, "")
	if len(got) == 0 {
		t.Fatal("no candidates returned")
	}
	// The real keyboard (full EV mask, non-excluded name) must come first;
	// "Power Button" and WMI hotkeys must be excluded entirely.
	if got[0] != "/dev/input/event10" {
		t.Fatalf("first candidate = %s, want /dev/input/event10 (all: %v)", got[0], got)
	}

	for _, p := range got {
		if p == "/dev/input/event0" || p == "/dev/input/event11" || p == "/dev/input/event4" {
			t.Fatalf("excluded device %s present in candidates: %v", p, got)
		}
	}
}

func TestSelectKeyboardDevicesNameFilter(t *testing.T) {
	devices := parseInputDevices(strings.NewReader(procBusInputDevicesKeyboardNamed))

	got := selectKeyboardDevices(devices, "asus")
	if len(got) != 1 || got[0] != "/dev/input/event20" {
		t.Fatalf("filter result = %v, want [/dev/input/event20]", got)
	}
}

func TestSelectKeyboardDevicesNamePriority(t *testing.T) {
	devices := parseInputDevices(strings.NewReader(procBusInputDevicesKeyboardNamed))

	got := selectKeyboardDevices(devices, "")
	if len(got) == 0 || got[0] != "/dev/input/event20" {
		t.Fatalf("first candidate = %v, want /dev/input/event20 (named keyboard wins)", got)
	}
}

func TestInputEvent64BitLayout(t *testing.T) {
	if got := binary.Size(InputEvent{}); got != 24 {
		t.Fatalf("InputEvent size = %d, want 24 bytes for 64-bit Linux", got)
	}
}

func TestInputEventDecoding64Bit(t *testing.T) {
	// Linux x86_64 input_event record: timeval(16) + type/code/value(8).
	buf := make([]byte, 24)
	binary.LittleEndian.PutUint64(buf[0:8], 123)
	binary.LittleEndian.PutUint64(buf[8:16], 456)
	binary.LittleEndian.PutUint16(buf[16:18], EvTypeKey)
	binary.LittleEndian.PutUint16(buf[18:20], 29)
	binary.LittleEndian.PutUint32(buf[20:24], EvValueKeyDown)

	var event InputEvent
	if err := binary.Read(bytes.NewReader(buf), binary.LittleEndian, &event); err != nil {
		t.Fatal(err)
	}

	if event.Sec != 123 || event.Usec != 456 || event.Type != EvTypeKey || event.Code != 29 || event.Value != EvValueKeyDown {
		t.Fatalf("decoded unexpected event: %+v", event)
	}
}
