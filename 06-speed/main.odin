package speed

import "core:bytes"
import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"
import "core:time"
import "core:thread"
import "core:os"
import "core:runtime"
import "core:sync"
import "core:testing"

THREAD_COUNT :: 128

LoggerOpts ::
    log.Options{.Level, .Terminal_Color, .Short_File_Path, .Line} | log.Full_Timestamp_Opts

main :: proc() {

    context.logger = log.create_console_logger(.Info, LoggerOpts)
    defer log.destroy_console_logger(context.logger)

    if len(os.args) != 2 {
        fmt.eprintln("Please pass only address:port as arg")
        os.exit(1)
    }

    listen_addr, lok := net.parse_endpoint(os.args[1])
    if !lok {
        fmt.eprintln("Error parsing endpoint to listen on")
        os.exit(1)
    }

    listener, lerr := net.listen_tcp(listen_addr)
    if lerr != nil {
        fmt.eprintln("Error setting up tcp listener", lerr)
        os.exit(1)
    }

    upstream_addr, _, uerr := net.resolve("chat.protohackers.com:16963")
    if uerr != nil {
        fmt.eprintln("Error parsing upstream endpoint")
        os.exit(1)
    }

    pool: thread.Pool
    thread.pool_init(&pool, context.allocator, THREAD_COUNT)
    defer thread.pool_destroy(&pool)
    thread.pool_start(&pool)

    log.infof(
        "Server started, listening on %v on %d threads",
        net.endpoint_to_string(listen_addr),
        THREAD_COUNT,
    )

    for {
        client_conn, client_addr, cerr := net.accept_tcp(listener)
        if cerr != nil do log.error(cerr)
        heartbeat := new(u32)

        state: ConnState
        state.client_conn = client_conn
        state.client_addr = client_addr
        state.heartbeat = heartbeat
        // Add main handler
        thread.pool_add_task(
            &pool,
            context.allocator,
            proc(t: thread.Task) {
                // Looks like logging is not thread-safe, but this is good enough for now.
                // https://github.com/odin-lang/Odin/blob/35857d3103b65020ce486571506aa69f53ad9a1a/core/log/file_console_logger.odin#L97-L98
                context = runtime.default_context()
                context.logger = log.create_console_logger(.Info, LoggerOpts)
                defer log.destroy_console_logger(context.logger)

                state := cast(^ConnState)t.data
                handle_conn(state^)
            },
            rawptr(&state),
        )
        thread.pool_add_task(&pool, context.allocator, proc(t: thread.Task) {
                state := cast(^ConnState)t.data
                handle_heartbeat(state^)
            }, rawptr(&state))

        // not needed, but cleans up the dynamic array tracking done tasks
        // will work better w/out tracking: https://github.com/odin-lang/Odin/pull/2668
        thread.pool_pop_done(&pool)
    }
}

ConnState :: struct {
    client_conn: net.TCP_Socket,
    client_addr: net.Endpoint,
    heartbeat:   ^u32,
}

handle_conn :: proc(state: ConnState) {
    client_conn := state.client_conn
    client_addr_str := fmt.tprintf("%d", state.client_addr.port)
    log.infof("%5s Connected", client_addr_str)

    defer {
        net.shutdown(client_conn, .Both)
        net.close(client_conn)
        log.infof("%5s Terminated", client_addr_str)
    }

    buf: [4096]u8 // enough to handle one tcp receive; will handle unfinished messages by manually advancing
    prefix_end_idx := 0
    for {
        // Read.
        n_bytes, rerr := net.recv_tcp(client_conn, buf[prefix_end_idx:])
        if rerr != nil || n_bytes == 0 {
            log.infof("%5s %v", client_addr_str, rerr)
            break
        }
        msg_batch_end_idx := prefix_end_idx + n_bytes

        // handle each message
        msg_idx := 0
        for {
            msg_type := message_type(buf[msg_idx])

            // parse in-place and directly act
            // harder to unit test, but more concise :)
            perr: ParseError
            msg_len := 0
            switch msg_type {
            case .NoMessage:
                perr = .Truncated
            case .Plate:
                str_len := buf[msg_idx + 1]
                str := buf[msg_idx + 2:][:str_len]
                timestamp := bytes_to_u32be(buf[msg_idx + 3 + int(str_len):][:4])
                log.infof("%5s Plate %s %d", client_addr_str, str, timestamp)
                msg_len = 1 + int(str_len) + 4
            case .WantHeartbeat:
                interval := bytes_to_u32be(buf[msg_idx + 1:][:4])
                log.infof("%5s WantHeartbeat %d", client_addr_str, interval)
                state.heartbeat^ = cast(u32)interval
                msg_len = 4
            case .IAmCamera:
                road := bytes_to_u16be(buf[msg_idx + 1:][:4])
                mile := bytes_to_u16be(buf[msg_idx + 5:][:4])
                limit := bytes_to_u16be(buf[msg_idx + 9:][:4])
                log.infof("%5s IAmCamera %d %d %d", client_addr_str, road, mile, limit)
                msg_len = 12
            case .IAmDispatcher:
                numroads := buf[msg_idx + 1]
                roads := transmute([]u16be)buf[msg_idx + 2:][:numroads * 2]
                log.infof("%5s IAmDispatcher %d %v", client_addr_str, numroads, roads)
                msg_len = 1 + (int(numroads) * 2)
            }

            // handle any errors from the parse-in-place phase
            switch perr {
            case .None:
            case .Truncated:
                copy(buf[:], buf[msg_idx:])
                prefix_end_idx = msg_batch_end_idx - msg_idx
                continue
            case .Malformed:
                log.errorf("parse msg malformed: %v", buf[msg_idx:])
                break
            }

            msg_idx += msg_len - 1
        }
    }
}

handle_heartbeat :: proc(state: ConnState) {
    client_conn := state.client_conn
    client_addr_str := fmt.tprintf("%d", state.client_addr.port)
    log.infof("%5s Heartbeat Connected", client_addr_str)

    defer {
        net.shutdown(client_conn, .Both)
        net.close(client_conn)
        log.infof("%5s Heartbeat Terminated", client_addr_str)
    }

    for {
        interval := cast(time.Duration)state.heartbeat^ * time.Millisecond * 100
        if state.heartbeat^ > 0 {
            log.infof("%5s Heartbeat send, interval %v", interval)
            n_bytes, serr := net.send_tcp(client_conn, {0x41})
            if serr != nil || n_bytes == 0 do break
            time.accurate_sleep(interval)
        }
    }
}

message_type :: proc(b: u8) -> ClientMsgType {
    switch b {
    case 0x20:
        return .Plate
    case 0x40:
        return .WantHeartbeat
    case 0x80:
        return .IAmCamera
    case 0x81:
        return .IAmDispatcher
    case:
        return .NoMessage
    }
}

ClientMsgType :: enum {
    NoMessage,
    Plate,
    WantHeartbeat,
    IAmCamera,
    IAmDispatcher,
}

ParseError :: enum {
    None,
    Truncated,
    Malformed,
}

bytes_to_u16be :: proc(slice: []u8) -> u16be {
    assert(len(slice) == 2)
    return (transmute(^u16be)raw_data(slice))^
}

bytes_to_u32be :: proc(slice: []u8) -> u32be {
    assert(len(slice) == 4)
    return (transmute(^u32be)raw_data(slice))^
}
