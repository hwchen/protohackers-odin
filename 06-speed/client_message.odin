package speed

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

// strings not allocated, they point to the buf
parse_message :: proc(buf: []u8) -> (msg: ClientMessage, msg_len: int, err: ParseError) {
    if len(buf) == 0 {
        err = .Truncated
        return
    }
    switch buf[0] {
    case 0x20:
        str_len := buf[1]
        plate := buf[2:][:str_len]
        timestamp := bytes_to_u32be(buf[3 + int(str_len):][:4])
        msg_len = 1 + int(str_len) + 4
        msg = Plate {
            plate     = transmute(string)plate,
            timestamp = timestamp,
        }
        return
    case 0x40:
        interval := bytes_to_u32be(buf[1:][:4])
        msg_len = 4
        msg = WantHeartbeat {
            interval = interval,
        }
        return
    case 0x80:
        road := bytes_to_u16be(buf[1:][:2])
        mile := bytes_to_u16be(buf[3:][:2])
        limit := bytes_to_u16be(buf[5:][:2])
        msg_len = 6
        msg = IAmCamera {
            road  = road,
            mile  = mile,
            limit = limit,
        }
        return
    case 0x81:
        numroads := buf[1]
        roads := transmute([]u16be)buf[2:][:numroads * 2]
        msg_len = 1 + (int(numroads) * 2)
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
}
