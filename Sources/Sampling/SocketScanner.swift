import Darwin
import Foundation

/// Reads each process's TCP sockets through libproc, so Watcher can tell which servers
/// have something connected to them (and what), before ever suggesting to quit one.
enum SocketScanner {
    struct Socket {
        let pid: Int32
        let localPort: UInt16
        let remotePort: UInt16
        let listening: Bool
        let established: Bool
        let remoteAddress: String
        var remoteIsLocal: Bool {
            remoteAddress == "127.0.0.1" || remoteAddress == "::1" || remoteAddress.hasPrefix("127.")
                || remoteAddress == "::ffff:127.0.0.1"
        }
    }

    static func scan(pids: [Int32]) -> [Socket] {
        var out: [Socket] = []
        var fdBuf = [proc_fdinfo](repeating: proc_fdinfo(), count: 512)
        for pid in pids {
            var bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fdBuf, Int32(fdBuf.count * MemoryLayout<proc_fdinfo>.stride))
            guard bytes > 0 else { continue }
            if Int(bytes) >= fdBuf.count * MemoryLayout<proc_fdinfo>.stride {
                fdBuf = [proc_fdinfo](repeating: proc_fdinfo(), count: fdBuf.count * 8)
                bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fdBuf, Int32(fdBuf.count * MemoryLayout<proc_fdinfo>.stride))
                guard bytes > 0 else { continue }
            }
            let n = Int(bytes) / MemoryLayout<proc_fdinfo>.stride
            for i in 0..<n where fdBuf[i].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                let r = proc_pidfdinfo(pid, fdBuf[i].proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
                guard r == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
                let tcp = info.psi.soi_proto.pri_tcp
                let ini = tcp.tcpsi_ini
                let lport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
                let fport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport))
                out.append(Socket(pid: pid, localPort: lport, remotePort: fport,
                                  listening: tcp.tcpsi_state == TSI_S_LISTEN,
                                  established: tcp.tcpsi_state == TSI_S_ESTABLISHED,
                                  remoteAddress: address(ini)))
            }
        }
        return out
    }

    private static func address(_ ini: in_sockinfo) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            var a = ini.insi_faddr.ina_46.i46a_addr4
            inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
        } else {
            var a = ini.insi_faddr.ina_6
            inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count))
        }
        return String(cString: buf)
    }

    /// Which things are connected to which servers.
    /// Returns, per server pid, the labels of its clients (other processes, or "a device at 192.168.1.5").
    static func clients(of sockets: [Socket]) -> (listen: [Int32: [UInt16]], clients: [Int32: [Client]]) {
        var listen: [Int32: [UInt16]] = [:]
        var listenerOf: [UInt16: Int32] = [:]
        for s in sockets where s.listening {
            listen[s.pid, default: []].append(s.localPort)
            listenerOf[s.localPort] = s.pid
        }
        // Local client sockets, keyed by (their port, the server port they talk to).
        var localClient: [String: Int32] = [:]
        for s in sockets where s.established { localClient["\(s.localPort)>\(s.remotePort)"] = s.pid }

        var out: [Int32: [Client]] = [:]
        for s in sockets where s.established {
            guard listenerOf[s.localPort] == s.pid else { continue }      // an accepted connection on our server port
            if s.remoteIsLocal {
                if let c = localClient["\(s.remotePort)>\(s.localPort)"], c != s.pid {
                    out[s.pid, default: []].append(Client(pid: c, remote: nil, port: s.localPort))
                }
            } else {
                out[s.pid, default: []].append(Client(pid: nil, remote: s.remoteAddress, port: s.localPort))
            }
        }
        return (listen.mapValues { Array(Set($0)).sorted() }, out)
    }

    struct Client: Hashable {
        let pid: Int32?
        let remote: String?
        let port: UInt16
    }
}
