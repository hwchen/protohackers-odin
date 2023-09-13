package smoke_test

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"

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

    log.infof("Server started, listening on %v", endpoint)

    for {
        conn, source, cerr := net.accept_tcp(listener)
        if cerr != nil do log.error(cerr)
        log.infof("Connection accepted from %v", source)

        buf: [4096]byte
        for {
            n_bytes, rerr := net.recv_tcp(conn, buf[:])
            if rerr != nil do log.error(rerr)

            if n_bytes == 0 do break

            _, werr := net.send_tcp(conn, buf[:n_bytes])
            if werr != nil do log.error(werr)
        }
        log.infof("Connection terminated from %v", source)
    }
}
