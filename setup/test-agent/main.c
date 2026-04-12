/*
 * test-agent/main.c — Simple HTTP server unikernel for testing Xen boot
 *
 * This is the simplest possible "agent" — it listens on port 8080 and
 * responds with a JSON payload. It exercises:
 *   - Network stack (lwip via Unikraft)
 *   - POSIX sockets
 *   - Basic I/O
 *
 * This is NOT production code — it's the minimum viable unikernel to
 * prove the Xen ↔ Unikraft ↔ Jitsu pipeline works.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>

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

int main(int argc, char *argv[])
{
    int port = PORT;
    const char *port_env = getenv("PORT");
    if (port_env) {
        port = atoi(port_env);
    }

    printf("=== Unikraft Test Agent ===\n");
    printf("Starting HTTP server on port %d...\n", port);

    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        return 1;
    }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_addr.s_addr = INADDR_ANY,
        .sin_port = htons(port),
    };

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(server_fd);
        return 1;
    }

    if (listen(server_fd, BACKLOG) < 0) {
        perror("listen");
        close(server_fd);
        return 1;
    }

    printf("Listening on 0.0.0.0:%d\n", port);
    printf("  GET  /health  — health check\n");
    printf("  POST /invoke  — agent invocation\n");
    printf("Ready.\n");

    while (1) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);

        int client_fd = accept(server_fd, (struct sockaddr *)&client_addr,
                               &client_len);
        if (client_fd < 0) {
            perror("accept");
            continue;
        }

        handle_request(client_fd);
    }

    close(server_fd);
    return 0;
}
