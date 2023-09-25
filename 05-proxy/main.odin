package proxy

import "core:bytes"
import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"
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
        upstream_conn, uerr := net.dial_tcp_from_endpoint(upstream_addr)
        if uerr != nil {
            log.error("Error connecting upstream", uerr)
            return
        }
        add_proxy_one_way(&pool, client_conn, client_addr, upstream_conn, upstream_addr)
        add_proxy_one_way(&pool, upstream_conn, upstream_addr, client_conn, client_addr)

        // not needed, but cleans up the dynamic array tracking done tasks
        // will work better w/out tracking: https://github.com/odin-lang/Odin/pull/2668
        thread.pool_pop_done(&pool)
    }
}

add_proxy_one_way :: proc(
    pool: ^thread.Pool,
    from_conn: net.TCP_Socket,
    from_addr: net.Endpoint,
    to_conn: net.TCP_Socket,
    to_addr: net.Endpoint,
) {
    state := new(ConnState)
    state.from_conn = from_conn
    state.from_addr = from_addr
    state.to_conn = to_conn
    state.to_addr = to_addr
    thread.pool_add_task(
        pool,
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
        rawptr(state),
    )
}

ConnState :: struct {
    from_conn: net.TCP_Socket,
    from_addr: net.Endpoint,
    to_conn:   net.TCP_Socket,
    to_addr:   net.Endpoint,
}

handle_conn :: proc(state: ConnState) {
    from_conn := state.from_conn
    to_conn := state.to_conn
    from_addr_str := fmt.tprintf("%d", state.from_addr.port)
    if state.from_addr.port == 16963 do from_addr_str = "chat"
    to_addr_str := fmt.tprintf("%d", state.to_addr.port)
    if state.to_addr.port == 16963 do to_addr_str = "chat"
    log.infof("from %5s Connected", from_addr_str)
    log.infof("to   %5s Connected", to_addr_str)

    defer {
        net.close(from_conn)
        net.close(to_conn)
        log.infof("from %5s Terminated", from_addr_str)
        log.infof("to   %5s Terminated", to_addr_str)
    }

    // Handling normal messages
    buf: [4096 * 1000]u8 // enough to handle an entire transaction; not streamed by line
    read_len := 0
    msg_batch: for {
        // Read. Continue reading if we don't end on a message boundary \n
        n_bytes, rerr := net.recv_tcp(from_conn, buf[read_len:])
        if rerr != nil do break
        if n_bytes == 0 do break
        read_len += n_bytes
        if buf[read_len - 1] != '\n' do continue
        log.infof("%5s -> %5s messages", from_addr_str, to_addr_str)

        // handle each message (line)
        lines := buf[:read_len]
        for line in bytes.split_iterator(&lines, {'\n'}) {
            new_msg := rewrite_coin(line) // temp alloc
            serr := send_msg(to_conn, new_msg)
            if serr != nil {
                log.errorf("%5s -> %5s, %v", from_addr_str, to_addr_str, serr)
                break msg_batch
            }
        }
        read_len = 0
    }
}

// temp alloc
rewrite_coin :: proc(msg: []u8) -> []u8 {
    TONY_ADDRESS := transmute([]u8)string("7YWHMfk9JZe0LM0g1ZauHuiSxhI")
    msg := msg
    res := make([dynamic]u8, context.temp_allocator)
    first := true
    for word in bytes.split_iterator(&msg, {' '}) {
        if !first do append(&res, ' ') // lazy space insertion
        first = false
        if is_coin(word) {
            append(&res, ..TONY_ADDRESS)
        } else {
            append(&res, ..word)
        }
    }
    return res[:]
}

is_coin :: proc(word: []u8) -> bool {
    if word[0] != '7' do return false
    if len(word) < 26 || len(word) > 35 do return false
    for c in word[1:] {
        switch c {
        case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
            continue
        case:
            return false
        }
    }
    return true
}

@(test)
test_is_coin :: proc(t: ^testing.T) {
    testing.expect(t, is_coin(transmute([]u8)string("7BNWw7PXmax0gzffJXbo41OefOvpsvngP")))
}

send_msg :: proc(conn: net.TCP_Socket, msg: []u8) -> (err: net.Network_Error) {
    net.send_tcp(conn, msg) or_return
    net.send_tcp(conn, {'\n'}) or_return
    return
}
