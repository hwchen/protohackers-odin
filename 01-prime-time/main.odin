package prime_time

import "core:fmt"
import "core:encoding/json"
import "core:log"
import "core:net"
import "core:thread"
import "core:os"
import "core:runtime"

THREAD_COUNT :: 128

main :: proc() {
    context.logger = log.create_console_logger(.Info)
    defer log.destroy_console_logger(context.logger)

    if len(os.args) != 2 {
        fmt.eprintln("Please pass only address:port as arg")
        os.exit(1)
    }

    endpoint, eok := net.parse_endpoint(os.args[1])
    if !eok {
        fmt.eprintln("Error parsing endpoint")
        os.exit(1)
    }

    listener, lerr := net.listen_tcp(endpoint)
    if lerr != nil {
        fmt.eprintln("Error setting up tcp listener", lerr)
        os.exit(1)
    }

    pool: thread.Pool
    thread.pool_init(&pool, context.allocator, THREAD_COUNT)
    defer thread.pool_destroy(&pool)
    thread.pool_start(&pool)

    log.infof("Server started, listening on %v on %d threads", endpoint, THREAD_COUNT)

    for {
        conn, source, cerr := net.accept_tcp(listener)
        if cerr != nil do log.error(cerr)

        state := new(ConnState)
        state.conn = conn
        state.source = source
        thread.pool_add_task(
            &pool,
            context.allocator,
            proc(t: thread.Task) {
                // Looks like logging is not thread-safe, but this is good enough for now.
                // https://github.com/odin-lang/Odin/blob/35857d3103b65020ce486571506aa69f53ad9a1a/core/log/file_console_logger.odin#L97-L98
                context = runtime.default_context()
                context.logger = log.create_console_logger(.Info)
                defer log.destroy_console_logger(context.logger)

                state := cast(^ConnState)t.data
                handle_conn(state.conn, state.source)
            },
            rawptr(state),
        )
        // not needed, but cleans up the dynamic array tracking done tasks
        // will work better w/out tracking: https://github.com/odin-lang/Odin/pull/2668
        thread.pool_pop_done(&pool)
    }
}

ConnState :: struct {
    conn:   net.TCP_Socket,
    source: net.Endpoint,
}

handle_conn :: proc(conn: net.TCP_Socket, source: net.Endpoint) {
    log.infof("Connection accepted from %v", source)
    defer {
        net.close(conn)
        log.infof("Connection terminated from %v", source)
    }

    buf: [4096]u8
    n_bytes, rerr := net.recv_tcp(conn, buf[:])
    if rerr != nil do log.error(rerr)

    j_tree, jerr := json.parse(buf[:n_bytes], parse_integers = true)
    if jerr != nil {
        log.error(jerr)
        send_malformed(conn, source)
        return
    }
    defer json.destroy_value(j_tree)

    // Note: this is actually pretty tidy; because of nil values being returned,
    // you can just continue trying to extract values, but only check all the successes
    // in one bunch at the end. This means all "err" handling can happen in one block.
    //
    // Perhaps dirtier than using pattern matching, but feels very practical. I should check if
    // it's somehow cursed.
    //
    // Pattern matching (or rust's if let syntax) is cleaner theoretically, but you need to nest, which
    // makes it hard to read. Would rust's chained if-let work similarly here?
    obj, ook := j_tree.(json.Object)
    method, mok := obj["method"].(string)
    num, nok := obj["number"].(i64)
    if ook && mok && nok && method == "isPrime" {
        send_is_prime(conn, source, is_prime(num))
    } else {
        send_malformed(conn, source)
    }
}

send_malformed :: proc(conn: net.TCP_Socket, source: net.Endpoint) {
    log.infof("Sending malformed to %v", source)
    _, werr := net.send_tcp(conn, {'{', '}'})
    if werr != nil do log.error(werr)
}

send_is_prime :: proc(conn: net.TCP_Socket, source: net.Endpoint, is_prime: bool) {
    out := fmt.tprint(`{"method":"isPrime","prime":`, is_prime, "}")
    defer delete(out)
    log.infof("Sending resp %s to %v", out, source)
    _, werr := net.send_tcp(conn, transmute([]u8)out)
    if werr != nil do log.error(werr)
}

is_prime :: proc(num: i64) -> bool {
    for i in 2 ..= num / 2 {
        if num % i != 0 do return false
    }
    return true
}
