/*
 * test-agent/main.c — Simple HTTP server unikernel for testing Xen boot
 *
 * This is the simplest possible "agent" — it listens on port 8080 and
 * responds with a JSON payload. It exercises:
 *   - Network stack (lwip via Unikraft)
 *   - POSIX sockets
 *   - Basic I/O
 *
 * UNIKERNEL CONSTRAINTS (no full libc):
 *   - No getenv() — port is hardcoded
 *   - No perror()  — use printf() for errors
 *   - No filesystem, no threads, no fork
 *   - Network initializes asynchronously on Xen PV
 *   - Must yield to cooperative scheduler for network to come up
 */

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <uk/sched.h>  /* uk_sched_yield — needed for cooperative scheduling */

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

/*
 * Yield to the cooperative scheduler many times.
 * This is CRITICAL on Xen PV: the netfront driver and lwIP stack
 * initialize via event channel callbacks that only run when the
 * scheduler processes them. A busy-wait spin loop will NOT work
 * because the scheduler never gets a chance to run.
 */
static void yield_delay(int iterations)
{
    for (int i = 0; i < iterations; i++) {
        uk_sched_yield();
    }
}

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
    printf("Starting HTTP server on port %d...\n", PORT);

    /*
     * On Xen PV with cooperative scheduling, the network stack (netfront +
     * lwIP) initializes via Xen event channel callbacks. These only fire
     * when we yield to the scheduler. We MUST yield before attempting
     * socket(), otherwise the network isn't ready and socket() fails.
     */
    printf("Waiting for network stack to initialize...\n");
    yield_delay(1000);  /* Give scheduler time to process netfront init */

    int server_fd = -1;
    int retries = 20;
    while (server_fd < 0 && retries > 0) {
        server_fd = socket(AF_INET, SOCK_STREAM, 0);
        if (server_fd < 0) {
            printf("socket() failed, yielding to scheduler... (%d attempts left)\n", retries);
            yield_delay(500);  /* Each retry: yield 500 times */
            retries--;
        }
    }
    if (server_fd < 0) {
        printf("Error: could not create socket after retries\n");
        printf("Entering idle loop (VM stays alive for debugging)\n");
        printf("Debug with: xl console test-agent\n");
        while (1) { uk_sched_yield(); }
    }
    printf("Socket created (fd=%d)\n", server_fd);

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(PORT);

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        printf("Error: bind() failed\n");
        printf("Entering idle loop for debugging\n");
        while (1) { uk_sched_yield(); }
    }
    printf("Bound to 0.0.0.0:%d\n", PORT);

    if (listen(server_fd, BACKLOG) < 0) {
        printf("Error: listen() failed\n");
        printf("Entering idle loop for debugging\n");
        while (1) { uk_sched_yield(); }
    }

    printf("Listening on 0.0.0.0:%d\n", PORT);
    printf("  GET  /health  — health check\n");
    printf("  POST /invoke  — agent invocation\n");
    printf("Ready.\n");

    while (1) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);

        int client_fd = accept(server_fd, (struct sockaddr *)&client_addr,
                               &client_len);
        if (client_fd < 0) {
            /* yield and retry — don't exit */
            uk_sched_yield();
            continue;
        }

        handle_request(client_fd);
    }

    close(server_fd);
    return 0;
}
