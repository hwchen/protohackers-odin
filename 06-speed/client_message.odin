package speed

import "core:fmt"
import "core:slice"
import "core:testing"

ClientMessage :: union {
	NoMessage,
	Plate,
	WantHeartbeat,
	IAmCamera,
	IAmDispatcher,
}
NoMessage :: distinct struct {}
Plate :: struct {
	plate:     string,
	timestamp: u32be,
}
WantHeartbeat :: struct {
	interval: u32be,
}
IAmCamera :: struct {
	road:  u16be,
	mile:  u16be,
	limit: u16be,
}
IAmDispatcher :: struct {
	numroads: u8,
	roads:    []u16be,
}

ParseError :: enum {
	None,
	Truncated,
	Malformed,
}

// strings and arrays not allocated, they point to the buf
parse_message :: proc(buf: []u8) -> (msg: ClientMessage, msg_len: int, err: ParseError) {
	if len(buf) == 0 {
		err = .Truncated
		return
	}
	switch buf[0] {
	case 0x20:
		str_len := buf[1]
		plate := buf[2:][:str_len]
		timestamp := bytes_to_u32be(buf[2 + int(str_len):][:4])
		msg_len = int(str_len) + 6
		msg = Plate {
			plate     = transmute(string)plate,
			timestamp = timestamp,
		}
		return
	case 0x40:
		interval := bytes_to_u32be(buf[1:][:4])
		msg_len = 5
		msg = WantHeartbeat {
			interval = interval,
		}
		return
	case 0x80:
		road := bytes_to_u16be(buf[1:][:2])
		mile := bytes_to_u16be(buf[3:][:2])
		limit := bytes_to_u16be(buf[5:][:2])
		msg_len = 7
		msg = IAmCamera {
			road  = road,
			mile  = mile,
			limit = limit,
		}
		return
	case 0x81:
		numroads := buf[1]
		roads := (transmute([]u16be)buf[2:])[:numroads]
		msg_len = 2 + (int(numroads) * 2)
		msg = IAmDispatcher {
			numroads = numroads,
			roads    = roads,
		}
		return
	case:
		err = .Truncated
		msg = NoMessage{}
		return
	}
}

bytes_to_u16be :: proc(slice: []u8) -> u16be {
	assert(len(slice) == 2)
	return (transmute(^u16be)raw_data(slice))^
}

bytes_to_u32be :: proc(slice: []u8) -> u32be {
	assert(len(slice) == 4)
	return (transmute(^u32be)raw_data(slice))^
}

@(test)
test_parse_message_empty_or_zero :: proc(t: ^testing.T) {
	{
		_, _, err := parse_message({})
		testing.expect_value(t, err, ParseError.Truncated)
	}
	{
		_, _, err := parse_message({0})
		testing.expect_value(t, err, ParseError.Truncated)
	}
}
@(test)
test_parse_message_plate :: proc(t: ^testing.T) {
	msg, msg_len, _ := parse_message({0x20, 0x04, 0x55, 0x4e, 0x31, 0x58, 0x00, 0x00, 0x03, 0xe8})
	m, mok := msg.(Plate)
	testing.expect(t, mok)
	testing.expect_value(t, msg_len, 10)
	testing.expect_value(t, m, Plate{plate = "UN1X", timestamp = 1000})
}
@(test)
test_parse_message_want_heartbeat :: proc(t: ^testing.T) {
	msg, msg_len, _ := parse_message({0x40, 0x00, 0x00, 0x00, 0x0a})
	m, mok := msg.(WantHeartbeat)
	testing.expect(t, mok)
	testing.expect_value(t, msg_len, 5)
	testing.expect_value(t, m, WantHeartbeat{interval = 10})
}
@(test)
test_parse_message_i_am_camera :: proc(t: ^testing.T) {
	msg, msg_len, _ := parse_message({0x80, 0x00, 0x42, 0x00, 0x64, 0x00, 0x3c})
	m, mok := msg.(IAmCamera)
	testing.expect(t, mok)
	testing.expect_value(t, msg_len, 7)
	testing.expect_value(t, m, IAmCamera{road = 66, mile = 100, limit = 60})
}
@(test)
test_parse_message_i_am_dispatcher :: proc(t: ^testing.T) {
	msg, msg_len, _ := parse_message({0x81, 0x03, 0x00, 0x42, 0x01, 0x70, 0x13, 0x88})
	m, mok := msg.(IAmDispatcher)
	testing.expect(t, mok)
	testing.expect_value(t, msg_len, 8)
	testing.expect_value(t, m.numroads, 3)
	err_msg := fmt.tprintf("Expected [66, 368, 5000], got %v", m.roads)
	testing.expect(t, slice.equal(m.roads, []u16be{66, 368, 5000}), err_msg)
}
