// Read-only macOS listener discovery, without lsof's filesystem/device scan.
#include <arpa/inet.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/proc_info.h>

static void json_string(const char *text) {
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
        if (*p == '"' || *p == '\\') { putchar('\\'); putchar(*p); }
        else if (*p < 32) printf("\\u%04x", *p);
        else putchar(*p);
    }
    putchar('"');
}

int main(int argc, char **argv) {
    int wanted = 0;
    if (argc > 2) return 2;
    if (argc == 2) {
        char *end;
        long value = strtol(argv[1], &end, 10);
        if (!*argv[1] || *end || value < 1 || value > 65535) return 2;
        wanted = (int)value;
    }
    int capacity = proc_listallpids(NULL, 0);
    if (capacity <= 0) return 1;
    capacity = capacity * 2 + 64;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    if (!pids) return 1;
    int count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    if (count <= 0 || count >= capacity) { free(pids); return 1; }
    int first = 1;
    putchar('[');
    for (int i = 0; i < count; i++) {
        if (pids[i] <= 0) continue;
        int size = proc_pidinfo(pids[i], PROC_PIDLISTFDS, 0, NULL, 0);
        if (size <= 0) continue; // Exited or inaccessible process.
        size += 64 * (int)sizeof(struct proc_fdinfo);
        struct proc_fdinfo *fds = malloc((size_t)size);
        if (!fds) { free(pids); return 1; }
        int bytes = proc_pidinfo(pids[i], PROC_PIDLISTFDS, 0, fds, size);
        char command[256] = {0};
        struct proc_vnodepathinfo cwd = {0};
        int have_metadata = 0, have_cwd = 0;
        for (int j = 0; j < bytes / (int)sizeof(*fds); j++) {
            if (fds[j].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
            struct socket_fdinfo socket = {0};
            if (proc_pidfdinfo(pids[i], fds[j].proc_fd, PROC_PIDFDSOCKETINFO, &socket, sizeof(socket)) != sizeof(socket)) continue;
            if (socket.psi.soi_kind != SOCKINFO_TCP || socket.psi.soi_proto.pri_tcp.tcpsi_state != TSI_S_LISTEN) continue;
            int port = ntohs((uint16_t)socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport);
            if (!port || (wanted && port != wanted)) continue;
            if (!have_metadata) {
                proc_name(pids[i], command, sizeof(command) - 1);
                have_cwd = proc_pidinfo(pids[i], PROC_PIDVNODEPATHINFO, 0, &cwd, sizeof(cwd)) == sizeof(cwd);
                have_metadata = 1;
            }
            if (!first) putchar(',');
            first = 0;
            printf("{\"pid\":%d,\"port\":%d,\"command\":", pids[i], port);
            json_string(command);
            printf(",\"projectPath\":");
            if (have_cwd && cwd.pvi_cdir.vip_path[0]) json_string(cwd.pvi_cdir.vip_path);
            else printf("null");
            putchar('}');
        }
        free(fds);
    }
    free(pids);
    puts("]");
    return ferror(stdout) ? 1 : 0;
}
