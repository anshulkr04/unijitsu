/*
 * test-agent/main.c — Simple HTTP server unikernel for testing Xen boot
 *
 * ONLY uses POSIX headers that Unikraft nolibc + posix libs actually provide.
 * NO: <stdlib.h>, <arpa/inet.h>, <time.h>, <uk/sched.h>
 * YES: <stdio.h>, <string.h>, <unistd.h>, <sys/socket.h>, <netinet/in.h>
 *
 * Uses sleep() (from posix-time) to yield to the cooperative scheduler,
 * which lets netfront + lwIP initialize before we call socket().
 */

#include <stdio.h>
#include <string.h>
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
    printf("Starting HTTP server on port %d...\n", PORT);

    /*
     * On Xen PV with cooperative scheduling, the network stack (netfront +
     * lwIP) initializes via Xen event channel callbacks. These only fire
     * when we yield to the scheduler. sleep() does this — it internally
     * blocks the thread and lets the scheduler run other work (including
     * processing Xen events that bring up the network).
     *
     * A busy-wait spin loop will NOT work because the cooperative scheduler
     * never gets a chance to run.
     */
    printf("Waiting for network stack to initialize...\n");
    sleep(15);  /* lwIP + netfront init takes several seconds on Xen PV */

    int server_fd = -1;
    int retries = 10;
    while (server_fd < 0 && retries > 0) {
        server_fd = socket(AF_INET, SOCK_STREAM, 0);
        if (server_fd < 0) {
            printf("socket() failed, waiting... (%d attempts left)\n", retries);
            sleep(1);  /* Yield to scheduler between retries */
            retries--;
        }
    }
    if (server_fd < 0) {
        printf("Error: could not create socket after retries\n");
        printf("VM staying alive for debugging — use: xl console test-agent\n");
        /* Keep VM alive so you can xl console to read this output */
        while (1) { sleep(60); }
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
        printf("VM staying alive for debugging\n");
        while (1) { sleep(60); }
    }
    printf("Bound to 0.0.0.0:%d\n", PORT);

    if (listen(server_fd, BACKLOG) < 0) {
        printf("Error: listen() failed\n");
        printf("VM staying alive for debugging\n");
        while (1) { sleep(60); }
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
            sleep(1);  /* yield and retry */
            continue;
        }

        handle_request(client_fd);
    }

    close(server_fd);
    return 0;
}
