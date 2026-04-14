/*
 * test-agent/main.c — Simple HTTP server unikernel for testing Xen boot
 *
 * ONLY uses POSIX headers that Unikraft nolibc + posix libs actually provide.
 * NO: <stdlib.h>, <arpa/inet.h>, <time.h>, <uk/sched.h>
 * YES: <stdio.h>, <string.h>, <errno.h>, <unistd.h>, <sys/socket.h>, <netinet/in.h>
 *
 * Uses sleep() (from posix-time) to yield to the cooperative scheduler,
 * which lets netfront + lwIP initialize before we call socket().
 *
 * DIAGNOSTIC: prints errno on every socket() failure so we stop guessing.
 *   errno=38 (ENOSYS)       -> CONFIG_LIBPOSIX_FDTAB not compiled in
 *   errno=97 (EAFNOSUPPORT) -> lwIP AF_INET not yet registered
 *   errno=12 (ENOMEM)       -> lwIP pool exhausted
 */

#include <stdio.h>
#include <string.h>
#include <errno.h>        /* errno values */
#include <unistd.h>       /* read, write, close, sleep */
#include <sys/socket.h>   /* socket, bind, listen, accept */
#include <netinet/in.h>   /* sockaddr_in, INADDR_ANY, htons */

#define PORT 8080
#define BUF_SIZE 4096
#define BACKLOG 16

static const char *RESPONSE_TEMPLATE =
    "HTTP/1.1 200 OK\r\n"
    "Content-Type: application/json\r\n"
    "Content-Length: %d\r\n"
    "Connection: close\r\n"
    "\r\n"
    "%s";

static const char *HEALTH_BODY =
    "{\"status\":\"ok\",\"agent\":\"test-agent\",\"runtime\":\"unikraft-xen\"}";

static const char *INVOKE_BODY =
    "{\"result\":\"hello from unikernel\",\"agent\":\"test-agent\","
    "\"message\":\"This response came from a Unikraft unikernel running on Xen.\"}";

static const char *NOT_FOUND_RESPONSE =
    "HTTP/1.1 404 Not Found\r\n"
    "Content-Type: application/json\r\n"
    "Content-Length: 24\r\n"
    "Connection: close\r\n"
    "\r\n"
    "{\"error\":\"not found\"}\r\n";

static void handle_request(int client_fd)
{
    char buf[BUF_SIZE];
    char response[BUF_SIZE];
    const char *body;

    ssize_t n = read(client_fd, buf, sizeof(buf) - 1);
    if (n <= 0) {
        close(client_fd);
        return;
    }
    buf[n] = '\0';

    /* Simple path routing */
    if (strstr(buf, "GET /health") != NULL) {
        body = HEALTH_BODY;
    } else if (strstr(buf, "POST /invoke") != NULL ||
               strstr(buf, "GET /invoke") != NULL) {
        body = INVOKE_BODY;
    } else if (strstr(buf, "GET / ") != NULL || strstr(buf, "GET /\r") != NULL) {
        body = HEALTH_BODY;
    } else {
        write(client_fd, NOT_FOUND_RESPONSE, strlen(NOT_FOUND_RESPONSE));
        close(client_fd);
        return;
    }

    int body_len = (int)strlen(body);
    int resp_len = snprintf(response, sizeof(response),
                            RESPONSE_TEMPLATE, body_len, body);

    write(client_fd, response, resp_len);
    close(client_fd);
}

int main(int argc __attribute__((unused)), char *argv[] __attribute__((unused)))
{
    printf("=== Unikraft Test Agent ===\n");
    printf("Build: " __DATE__ " " __TIME__ "\n");

    /*
     * Probe socket() every 2s and print errno each time.
     * This gives a running diagnostic log on xl console:
     *
     *   errno=38 (ENOSYS)       -> CONFIG_LIBPOSIX_FDTAB missing in Kraftfile
     *   errno=97 (EAFNOSUPPORT) -> fdtab OK but lwIP not registered AF_INET yet
     *   errno=12 (ENOMEM)       -> lwIP pool not initialized
     *
     * If errno=38 forever: rebuild with CONFIG_LIBPOSIX_FDTAB: 'y'
     * If errno=97 forever: lwIP init not running (scheduler/threading issue)
     */
    printf("Probing socket(AF_INET, SOCK_STREAM) every 2s (max 60s)...\n");

    int server_fd = -1;
    int elapsed = 0;
    while (server_fd < 0 && elapsed < 60) {
        server_fd = socket(AF_INET, SOCK_STREAM, 0);
        if (server_fd < 0) {
            printf("[t=%02ds] socket() FAILED errno=%d\n", elapsed, errno);
            sleep(2);
            elapsed += 2;
        }
    }
    if (server_fd < 0) {
        printf("FATAL: socket() FAILED for %ds, last errno=%d\n", elapsed, errno);
        printf("  errno=38 -> CONFIG_LIBPOSIX_FDTAB: 'y' missing\n");
        printf("  errno=97 -> lwIP AF_INET not registered (lwIP init broken)\n");
        printf("  errno=12 -> lwIP memory pool issue\n");
        printf("Keeping VM alive: sudo xl console test-agent\n");
        while (1) { sleep(60); }
    }
    printf("[OK] socket() at t=%ds fd=%d\n", elapsed, server_fd);

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(PORT);

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        printf("FATAL: bind(0.0.0.0:%d) FAILED errno=%d\n", PORT, errno);
        printf("  errno=99 (EADDRNOTAVAIL) -> IP not yet on netdev\n");
        printf("  errno=98 (EADDRINUSE)    -> port in use\n");
        printf("Keeping VM alive: sudo xl console test-agent\n");
        while (1) { sleep(60); }
    }
    printf("[OK] bind(0.0.0.0:%d)\n", PORT);

    if (listen(server_fd, BACKLOG) < 0) {
        printf("FATAL: listen() errno=%d\n", errno);
        while (1) { sleep(60); }
    }

    printf("[OK] HTTP server READY on 0.0.0.0:%d\n", PORT);
    printf("  GET  /health  -> health check\n");
    printf("  POST /invoke  -> agent invocation\n");
    printf("READY. Waiting for connections...\n");

    while (1) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);

        int client_fd = accept(server_fd, (struct sockaddr *)&client_addr,
                               &client_len);
        if (client_fd < 0) {
            sleep(1);  /* yield and retry */
            continue;
        }

        handle_request(client_fd);
    }

    close(server_fd);
    return 0;
}
