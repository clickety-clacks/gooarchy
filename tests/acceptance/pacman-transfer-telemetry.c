#define _GNU_SOURCE

#include <arpa/inet.h>
#include <ctype.h>
#include <curl/curl.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define HOST_CAP 256
#define PATH_CAP 768
#define METHOD_CAP 16
#define ID_CAP 129
#define LINE_CAP 8192
#define URL_CAP 4096

typedef CURL *(*curl_easy_init_fn)(void);
typedef CURLcode (*curl_easy_perform_fn)(CURL *);
typedef void (*curl_easy_cleanup_fn)(CURL *);

struct line_buffer {
  char data[LINE_CAP];
  size_t length;
  int discard;
};

struct hop {
  int active;
  unsigned int number;
  char method[METHOD_CAP];
  char scheme[8];
  char host[HOST_CAP];
  char path[PATH_CAP];
  long status;
  long curl_code;
  int has_curl_code;
  unsigned long long started_ns;
  unsigned long long request_header_bytes;
  unsigned long long request_body_bytes;
  unsigned long long header_bytes;
  unsigned long long body_bytes;
  char request_id[ID_CAP];
  char request_id_header[32];
  char redirect_host[HOST_CAP];
  char redirect_path[PATH_CAP];
};

struct handle_state {
  CURL *curl;
  unsigned long long transfer_id;
  unsigned int next_hop;
  char telemetry_path[URL_CAP];
  struct hop current;
  char pending_method[METHOD_CAP];
  char pending_scheme[8];
  char pending_host[HOST_CAP];
  char pending_path[PATH_CAP];
  int has_pending_request;
  unsigned long long pending_header_bytes;
  struct line_buffer outgoing;
  struct line_buffer incoming;
  struct handle_state *next;
};

static curl_easy_init_fn real_curl_easy_init;
static curl_easy_perform_fn real_curl_easy_perform;
static curl_easy_cleanup_fn real_curl_easy_cleanup;
static struct handle_state *handles;
static unsigned long long next_transfer_id = 1;
static pthread_once_t symbols_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t handles_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t output_mutex = PTHREAD_MUTEX_INITIALIZER;

static void resolve_symbols(void) {
  *(void **)(&real_curl_easy_init) = dlsym(RTLD_NEXT, "curl_easy_init");
  *(void **)(&real_curl_easy_perform) = dlsym(RTLD_NEXT, "curl_easy_perform");
  *(void **)(&real_curl_easy_cleanup) = dlsym(RTLD_NEXT, "curl_easy_cleanup");
}

static unsigned long long monotonic_ns(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
    return 0;
  }
  return (unsigned long long)now.tv_sec * 1000000000ULL +
         (unsigned long long)now.tv_nsec;
}

static void copy_bounded(char *destination, size_t capacity,
                         const char *source) {
  if (capacity == 0) {
    return;
  }
  size_t length = strnlen(source, capacity - 1);
  memcpy(destination, source, length);
  destination[length] = '\0';
}

static int allowed_char(unsigned char ch, const char *allowed) {
  return strchr(allowed, (int)ch) != NULL;
}

static int host_is_private_or_local(const char *host) {
  char value[HOST_CAP];
  copy_bounded(value, sizeof(value), host);
  size_t length = strlen(value);
  if (length == 0) {
    return 1;
  }

  if (value[0] == '[') {
    char *end = strchr(value, ']');
    if (end != NULL) {
      *end = '\0';
      memmove(value, value + 1, strlen(value));
    }
  } else {
    char *first_colon = strchr(value, ':');
    char *last_colon = strrchr(value, ':');
    if (first_colon != NULL && first_colon == last_colon) {
      *first_colon = '\0';
    }
  }

  for (size_t i = 0; value[i]; ++i) {
    if (value[i] >= 'A' && value[i] <= 'Z') {
      value[i] = (char)(value[i] - 'A' + 'a');
    }
  }
  if (strcmp(value, "localhost") == 0 || strcmp(value, "::1") == 0 ||
      strcmp(value, "0.0.0.0") == 0 || strcmp(value, "::") == 0) {
    return 1;
  }
  if (strncasecmp(value, "fe80:", 5) == 0) {
    return 1;
  }
  if (strchr(value, '.') == NULL && strchr(value, ':') == NULL) {
    return 1;
  }
  size_t value_length = strlen(value);
  const char *local_suffixes[] = {".local", ".internal", ".lan", ".localhost",
                                  ".corp", ".home", ".test"};
  for (size_t i = 0;
       i < sizeof(local_suffixes) / sizeof(local_suffixes[0]); ++i) {
    size_t suffix_length = strlen(local_suffixes[i]);
    if (value_length >= suffix_length &&
        strcmp(value + value_length - suffix_length, local_suffixes[i]) == 0) {
      return 1;
    }
  }

  struct in_addr ipv4;
  if (inet_pton(AF_INET, value, &ipv4) == 1) {
    unsigned int address = ntohl(ipv4.s_addr);
    unsigned int first = address >> 24;
    unsigned int second = (address >> 16) & 0xffU;
    if (first == 0 || first == 10 || first == 127 || first >= 224 ||
        (first == 169 && second == 254) ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168)) {
      return 1;
    }
  }

  struct in6_addr ipv6;
  if (inet_pton(AF_INET6, value, &ipv6) == 1) {
    if (IN6_IS_ADDR_LOOPBACK(&ipv6) || IN6_IS_ADDR_LINKLOCAL(&ipv6) ||
        (ipv6.s6_addr[0] & 0xfeU) == 0xfcU) {
      return 1;
    }
  }
  return 0;
}

static void clean_host(char *value) {
  static const char allowed[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-:[]";
  char cleaned[HOST_CAP];
  size_t output = 0;
  for (size_t i = 0; value[i] && output + 1 < sizeof(cleaned); ++i) {
    if (allowed_char((unsigned char)value[i], allowed)) {
      cleaned[output++] = value[i];
    }
  }
  cleaned[output] = '\0';
  if (host_is_private_or_local(cleaned)) {
    copy_bounded(value, HOST_CAP, "[redacted]");
  } else {
    copy_bounded(value, HOST_CAP, cleaned);
  }
}

static void clean_path(char *value) {
  static const char allowed[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
      "/%._~!$&'()*+,;=:@-[]";
  char cleaned[PATH_CAP];
  size_t output = 0;
  for (size_t i = 0; value[i] && value[i] != '?' && value[i] != '#'; ++i) {
    if (allowed_char((unsigned char)value[i], allowed) &&
        output + 1 < sizeof(cleaned)) {
      cleaned[output++] = value[i];
    }
  }
  if (output == 0 || cleaned[0] != '/') {
    if (output + 1 < sizeof(cleaned)) {
      memmove(cleaned + 1, cleaned, output);
      cleaned[0] = '/';
      ++output;
    }
  }
  cleaned[output] = '\0';

  char redacted[PATH_CAP];
  size_t redacted_length = 0;
  const char *segment = cleaned;
  int redact_next = 0;
  while (*segment && redacted_length + 1 < sizeof(redacted)) {
    const char *end = strchr(segment, '/');
    size_t segment_length = end != NULL ? (size_t)(end - segment)
                                        : strlen(segment);
    if (segment_length == 0) {
      redacted[redacted_length++] = '/';
    } else {
      char segment_text[PATH_CAP];
      size_t bounded = segment_length < sizeof(segment_text) - 1
                           ? segment_length
                           : sizeof(segment_text) - 1;
      memcpy(segment_text, segment, bounded);
      segment_text[bounded] = '\0';
      int sensitive_label = strcasecmp(segment_text, "token") == 0 ||
                            strcasecmp(segment_text, "signature") == 0 ||
                            strcasecmp(segment_text, "sig") == 0 ||
                            strcasecmp(segment_text, "auth") == 0 ||
                            strcasecmp(segment_text, "authorization") == 0 ||
                            strcasecmp(segment_text, "key") == 0 ||
                            strcasecmp(segment_text, "api-key") == 0 ||
                            strcasecmp(segment_text, "apikey") == 0 ||
                            strcasecmp(segment_text, "secret") == 0 ||
                            strcasecmp(segment_text, "password") == 0 ||
                            strcasecmp(segment_text, "credential") == 0 ||
                            strcasecmp(segment_text, "access_token") == 0 ||
                            strcasecmp(segment_text, "access-token") == 0;
      int opaque_value = 0;
      if (segment_length >= 24) {
        opaque_value = 1;
        for (size_t i = 0; i < segment_length; ++i) {
          unsigned char ch = (unsigned char)segment[i];
          if (!(isalnum(ch) || ch == '_' || ch == '-' || ch == '=' ||
                ch == '+')) {
            opaque_value = 0;
            break;
          }
        }
      }
      int redact = redact_next || opaque_value;
      const char *replacement = redact ? "[redacted]" : segment_text;
      size_t replacement_length = strlen(replacement);
      if (redacted_length + replacement_length >= sizeof(redacted)) {
        break;
      }
      memcpy(redacted + redacted_length, replacement, replacement_length);
      redacted_length += replacement_length;
      redact_next = sensitive_label;
    }
    if (end == NULL) {
      break;
    }
    segment = end + 1;
  }
  redacted[redacted_length] = '\0';
  copy_bounded(value, PATH_CAP, redacted);
}

static void clean_method(char *value) {
  static const char allowed[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-";
  char cleaned[METHOD_CAP];
  size_t output = 0;
  for (size_t i = 0; value[i] && output + 1 < sizeof(cleaned); ++i) {
    if (allowed_char((unsigned char)value[i], allowed)) {
      cleaned[output++] = value[i];
    }
  }
  cleaned[output] = '\0';
  copy_bounded(value, METHOD_CAP, output > 0 ? cleaned : "GET");
}

static void clean_scheme(char *value) {
  static const char allowed[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+.-";
  char cleaned[8];
  size_t output = 0;
  for (size_t i = 0; value[i] && output + 1 < sizeof(cleaned); ++i) {
    if (allowed_char((unsigned char)value[i], allowed)) {
      cleaned[output++] = value[i];
    }
  }
  cleaned[output] = '\0';
  copy_bounded(value, 8, output > 0 ? cleaned : "https");
}

static int clean_id(const char *value, char *output, size_t capacity) {
  static const char allowed[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-+/=";
  size_t length = 0;
  while (*value == ' ' || *value == '\t') {
    ++value;
  }
  while (value[length] && value[length] != '\r' && value[length] != '\n' &&
         value[length] != ' ' && value[length] != '\t') {
    if (!allowed_char((unsigned char)value[length], allowed) ||
        length + 1 >= capacity || length >= 128) {
      output[0] = '\0';
      return 0;
    }
    ++length;
  }
  if (length == 0) {
    output[0] = '\0';
    return 0;
  }
  memcpy(output, value, length);
  output[length] = '\0';
  return 1;
}

static void append_line(const char *path, const char *line, size_t length) {
  if (path[0] == '\0') {
    return;
  }
  pthread_mutex_lock(&output_mutex);
  int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
  if (fd >= 0) {
    (void)fchmod(fd, 0600);
    size_t offset = 0;
    while (offset < length) {
      ssize_t written = write(fd, line + offset, length - offset);
      if (written < 0) {
        if (errno == EINTR) {
          continue;
        }
        break;
      }
      offset += (size_t)written;
    }
    close(fd);
  }
  pthread_mutex_unlock(&output_mutex);
}

static void emit_ready(const char *path) {
  char line[128];
  int length = snprintf(line, sizeof(line),
                        "{\"event\":\"telemetry_ready\",\"pid\":%ld}\n",
                        (long)getpid());
  if (length > 0 && (size_t)length < sizeof(line)) {
    append_line(path, line, (size_t)length);
  }
}

static void emit_hop(struct handle_state *state) {
  struct hop *hop = &state->current;
  if (!hop->active) {
    return;
  }
  unsigned long long finished_ns = monotonic_ns();
  unsigned long long elapsed_ms =
      finished_ns >= hop->started_ns
          ? (finished_ns - hop->started_ns) / 1000000ULL
          : 0;
  char curl_code[32];
  if (hop->has_curl_code) {
    snprintf(curl_code, sizeof(curl_code), "%ld", hop->curl_code);
  } else {
    copy_bounded(curl_code, sizeof(curl_code), "null");
  }
  char line[4096];
  int length = snprintf(
      line, sizeof(line),
      "{\"event\":\"http_hop\",\"transfer_id\":%llu,\"hop\":%u,"
      "\"method\":\"%s\",\"scheme\":\"%s\",\"host\":\"%s\","
      "\"path\":\"%s\",\"status\":%ld,\"curl_code\":%s,"
      "\"elapsed_ms\":%llu,\"request_header_bytes\":%llu,"
      "\"request_body_bytes\":%llu,\"response_header_bytes\":%llu,"
      "\"response_body_bytes\":%llu,\"request_id_header\":%s%s%s,"
      "\"request_id\":%s%s%s,\"redirect_host\":%s%s%s,"
      "\"redirect_path\":%s%s%s}\n",
      state->transfer_id, hop->number, hop->method, hop->scheme, hop->host,
      hop->path, hop->status, curl_code, elapsed_ms,
      hop->request_header_bytes, hop->request_body_bytes, hop->header_bytes,
      hop->body_bytes, hop->request_id_header[0] ? "\"" : "null",
      hop->request_id_header[0] ? hop->request_id_header : "",
      hop->request_id_header[0] ? "\"" : "",
      hop->request_id[0] ? "\"" : "null",
      hop->request_id[0] ? hop->request_id : "",
      hop->request_id[0] ? "\"" : "",
      hop->redirect_host[0] ? "\"" : "null",
      hop->redirect_host[0] ? hop->redirect_host : "",
      hop->redirect_host[0] ? "\"" : "",
      hop->redirect_path[0] ? "\"" : "null",
      hop->redirect_path[0] ? hop->redirect_path : "",
      hop->redirect_path[0] ? "\"" : "");
  if (length > 0 && (size_t)length < sizeof(line)) {
    append_line(state->telemetry_path, line, (size_t)length);
  }
  memset(hop, 0, sizeof(*hop));
}

static void parse_url(const char *url, char *scheme, size_t scheme_capacity,
                      char *host, size_t host_capacity, char *path,
                      size_t path_capacity) {
  CURLU *parsed = curl_url();
  if (parsed == NULL) {
    return;
  }
  if (curl_url_set(parsed, CURLUPART_URL, url, CURLU_NON_SUPPORT_SCHEME) ==
      CURLUE_OK) {
    char *part = NULL;
    if (curl_url_get(parsed, CURLUPART_SCHEME, &part, 0) == CURLUE_OK) {
      copy_bounded(scheme, scheme_capacity, part);
      curl_free(part);
    }
    part = NULL;
    if (curl_url_get(parsed, CURLUPART_HOST, &part, 0) == CURLUE_OK) {
      copy_bounded(host, host_capacity, part);
      curl_free(part);
    }
    part = NULL;
    if (curl_url_get(parsed, CURLUPART_PATH, &part, 0) == CURLUE_OK) {
      copy_bounded(path, path_capacity, part);
      curl_free(part);
    }
  }
  curl_url_cleanup(parsed);
}

static void set_redirect(struct hop *hop, const char *location) {
  char base[HOST_CAP + PATH_CAP + 32];
  char resolved_host[HOST_CAP] = "";
  char resolved_scheme[8] = "https";
  char resolved_path[PATH_CAP] = "";
  if (location[0] == '\0' || hop->host[0] == '\0') {
    return;
  }
  int base_length = snprintf(base, sizeof(base), "%s://%s%s",
                            hop->scheme[0] ? hop->scheme : "https", hop->host,
                            hop->path[0] ? hop->path : "/");
  if (base_length < 0 || (size_t)base_length >= sizeof(base)) {
    return;
  }
  CURLU *parsed = curl_url();
  if (parsed == NULL) {
    return;
  }
  if (curl_url_set(parsed, CURLUPART_URL, base, CURLU_NON_SUPPORT_SCHEME) ==
          CURLUE_OK &&
      curl_url_set(parsed, CURLUPART_URL, location, CURLU_NON_SUPPORT_SCHEME) ==
          CURLUE_OK) {
    char *part = NULL;
    if (curl_url_get(parsed, CURLUPART_SCHEME, &part, 0) == CURLUE_OK) {
      copy_bounded(resolved_scheme, sizeof(resolved_scheme), part);
      curl_free(part);
    }
    part = NULL;
    if (curl_url_get(parsed, CURLUPART_HOST, &part, 0) == CURLUE_OK) {
      copy_bounded(resolved_host, sizeof(resolved_host), part);
      curl_free(part);
    }
    part = NULL;
    if (curl_url_get(parsed, CURLUPART_PATH, &part, 0) == CURLUE_OK) {
      copy_bounded(resolved_path, sizeof(resolved_path), part);
      curl_free(part);
    }
  }
  curl_url_cleanup(parsed);
  (void)resolved_scheme;
  clean_host(resolved_host);
  clean_path(resolved_path);
  if (resolved_host[0]) {
    copy_bounded(hop->redirect_host, sizeof(hop->redirect_host), resolved_host);
    copy_bounded(hop->redirect_path, sizeof(hop->redirect_path), resolved_path);
  }
}

static void start_hop(struct handle_state *state) {
  if (!state->has_pending_request) {
    return;
  }
  emit_hop(state);
  memset(&state->current, 0, sizeof(state->current));
  state->current.active = 1;
  state->current.number = ++state->next_hop;
  state->current.curl_code = -1;
  state->current.started_ns = monotonic_ns();
  state->current.request_header_bytes = state->pending_header_bytes;
  state->pending_header_bytes = 0;
  copy_bounded(state->current.method, sizeof(state->current.method),
               state->pending_method[0] ? state->pending_method : "GET");
  copy_bounded(state->current.scheme, sizeof(state->current.scheme),
               state->pending_scheme[0] ? state->pending_scheme : "https");
  copy_bounded(state->current.host, sizeof(state->current.host),
               state->pending_host);
  copy_bounded(state->current.path, sizeof(state->current.path),
               state->pending_path[0] ? state->pending_path : "/");
  clean_method(state->current.method);
  clean_scheme(state->current.scheme);
  clean_host(state->current.host);
  clean_path(state->current.path);
  state->has_pending_request = 0;
  state->pending_method[0] = '\0';
  state->pending_scheme[0] = '\0';
  state->pending_host[0] = '\0';
  state->pending_path[0] = '\0';
}

static int is_request_id_header(const char *name, char *canonical,
                                size_t capacity) {
  static const char *const names[] = {
      "x-request-id",     "request-id",       "x-correlation-id",
      "x-amzn-requestid", "x-amz-request-id", "x-amz-cf-id",
      "x-amz-id-2",       "x-ms-request-id",  "x-azure-ref",
      "x-goog-request-id", "cf-ray"};
  for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
    if (strcasecmp(name, names[i]) == 0) {
      copy_bounded(canonical, capacity, names[i]);
      return 1;
    }
  }
  return 0;
}

static void parse_out_line(struct handle_state *state, char *line) {
  char *value;
  if (line[0] == '\0') {
    start_hop(state);
    return;
  }
  if (strncasecmp(line, ":method:", 8) == 0) {
    value = line + 8;
    while (*value == ' ' || *value == '\t') ++value;
    copy_bounded(state->pending_method, sizeof(state->pending_method), value);
    state->has_pending_request = 1;
    return;
  }
  if (strncasecmp(line, ":path:", 6) == 0) {
    value = line + 6;
    while (*value == ' ' || *value == '\t') ++value;
    copy_bounded(state->pending_path, sizeof(state->pending_path), value);
    state->has_pending_request = 1;
    return;
  }
  if (strncasecmp(line, ":scheme:", 8) == 0) {
    value = line + 8;
    while (*value == ' ' || *value == '\t') ++value;
    copy_bounded(state->pending_scheme, sizeof(state->pending_scheme), value);
    state->has_pending_request = 1;
    return;
  }
  if (strncasecmp(line, ":authority:", 11) == 0 ||
      strncasecmp(line, "Host:", 5) == 0) {
    value = line + (line[0] == ':' ? 11 : 5);
    while (*value == ' ' || *value == '\t') ++value;
    copy_bounded(state->pending_host, sizeof(state->pending_host), value);
    state->has_pending_request = 1;
    return;
  }

  char *first_space = strchr(line, ' ');
  if (first_space == NULL || strchr(line, ':') != NULL) {
    return;
  }
  *first_space = '\0';
  char *target = first_space + 1;
  while (*target == ' ') ++target;
  char *second_space = strchr(target, ' ');
  if (second_space == NULL || strncasecmp(second_space + 1, "HTTP/", 5) != 0) {
    return;
  }
  *second_space = '\0';
  copy_bounded(state->pending_method, sizeof(state->pending_method), line);
  if (strstr(target, "://") != NULL) {
    parse_url(target, state->pending_scheme, sizeof(state->pending_scheme),
              state->pending_host, sizeof(state->pending_host),
              state->pending_path, sizeof(state->pending_path));
  } else if (strcasecmp(line, "CONNECT") == 0) {
    copy_bounded(state->pending_host, sizeof(state->pending_host), target);
    copy_bounded(state->pending_path, sizeof(state->pending_path), "/");
  } else {
    copy_bounded(state->pending_path, sizeof(state->pending_path), target);
  }
  state->has_pending_request = 1;
}

static void parse_in_line(struct handle_state *state, char *line) {
  struct hop *hop = &state->current;
  if (line[0] == '\0') {
    return;
  }
  if (strncasecmp(line, "HTTP/", 5) == 0) {
    if (!hop->active && state->has_pending_request) {
      start_hop(state);
      hop = &state->current;
    }
    char *space = strchr(line, ' ');
    if (space != NULL && hop->active) {
      hop->status = strtol(space + 1, NULL, 10);
      hop->request_id[0] = '\0';
      hop->request_id_header[0] = '\0';
    }
    return;
  }
  if (!hop->active) {
    return;
  }
  if (strncasecmp(line, "Location:", 9) == 0 && hop->status >= 300 &&
      hop->status < 400) {
    char *value = line + 9;
    while (*value == ' ' || *value == '\t') ++value;
    set_redirect(hop, value);
    return;
  }
  char *colon = strchr(line, ':');
  if (colon == NULL) {
    return;
  }
  *colon = '\0';
  char canonical[32] = "";
  if (is_request_id_header(line, canonical, sizeof(canonical))) {
    char safe_value[ID_CAP] = "";
    if (clean_id(colon + 1, safe_value, sizeof(safe_value))) {
      copy_bounded(hop->request_id, sizeof(hop->request_id), safe_value);
      copy_bounded(hop->request_id_header, sizeof(hop->request_id_header),
                   canonical);
    }
  }
}

static void feed_lines(struct line_buffer *buffer, const char *data, size_t size,
                      struct handle_state *state, int outgoing) {
  for (size_t i = 0; i < size; ++i) {
    char ch = data[i];
    if (ch == '\n') {
      if (!buffer->discard) {
        if (buffer->length > 0 && buffer->data[buffer->length - 1] == '\r') {
          --buffer->length;
        }
        buffer->data[buffer->length] = '\0';
        if (outgoing) {
          parse_out_line(state, buffer->data);
        } else {
          parse_in_line(state, buffer->data);
        }
      }
      buffer->length = 0;
      buffer->discard = 0;
      continue;
    }
    if (buffer->discard) {
      continue;
    }
    if (buffer->length + 1 >= sizeof(buffer->data)) {
      buffer->length = 0;
      buffer->discard = 1;
      continue;
    }
    buffer->data[buffer->length++] = ch;
  }
}

static int debug_callback(CURL *curl, curl_infotype type, char *data,
                          size_t size, void *user_data) {
  (void)curl;
  struct handle_state *state = user_data;
  if (state == NULL || !state->telemetry_path[0]) {
    return 0;
  }
  if (type == CURLINFO_HEADER_OUT) {
    state->pending_header_bytes += size;
    feed_lines(&state->outgoing, data, size, state, 1);
  } else if (type == CURLINFO_HEADER_IN) {
    if (state->current.active) {
      state->current.header_bytes += size;
    }
    feed_lines(&state->incoming, data, size, state, 0);
  } else if (type == CURLINFO_DATA_IN && state->current.active) {
    state->current.body_bytes += size;
  } else if (type == CURLINFO_DATA_OUT && state->current.active) {
    state->current.request_body_bytes += size;
  }
  return 0;
}

static struct handle_state *find_state(CURL *curl) {
  pthread_mutex_lock(&handles_mutex);
  struct handle_state *state = handles;
  while (state != NULL && state->curl != curl) {
    state = state->next;
  }
  pthread_mutex_unlock(&handles_mutex);
  return state;
}

__attribute__((constructor)) static void telemetry_library_loaded(void) {
  const char *path = getenv("GOOARCHY_TRANSFER_TELEMETRY");
  if (path != NULL) {
    emit_ready(path);
  }
}

CURL *curl_easy_init(void) {
  pthread_once(&symbols_once, resolve_symbols);
  if (real_curl_easy_init == NULL) {
    return NULL;
  }
  CURL *curl = real_curl_easy_init();
  if (curl == NULL) {
    return NULL;
  }
  struct handle_state *state = calloc(1, sizeof(*state));
  if (state == NULL) {
    return curl;
  }
  state->curl = curl;
  const char *path = getenv("GOOARCHY_TRANSFER_TELEMETRY");
  if (path != NULL) {
    copy_bounded(state->telemetry_path, sizeof(state->telemetry_path), path);
  }
  pthread_mutex_lock(&handles_mutex);
  state->transfer_id = next_transfer_id++;
  state->next = handles;
  handles = state;
  pthread_mutex_unlock(&handles_mutex);
  return curl;
}

CURLcode curl_easy_perform(CURL *curl) {
  pthread_once(&symbols_once, resolve_symbols);
  if (real_curl_easy_perform == NULL) {
    return CURLE_FAILED_INIT;
  }
  struct handle_state *state = find_state(curl);
  if (state != NULL && state->telemetry_path[0]) {
    (void)curl_easy_setopt(curl, CURLOPT_VERBOSE, 1L);
    (void)curl_easy_setopt(curl, CURLOPT_DEBUGFUNCTION, debug_callback);
    (void)curl_easy_setopt(curl, CURLOPT_DEBUGDATA, state);
    if (!state->has_pending_request) {
      char *url = NULL;
      if (curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &url) == CURLE_OK &&
          url != NULL) {
        parse_url(url, state->pending_scheme, sizeof(state->pending_scheme),
                  state->pending_host, sizeof(state->pending_host),
                  state->pending_path, sizeof(state->pending_path));
        state->has_pending_request = state->pending_host[0] != '\0';
      }
    }
  }
  CURLcode result = real_curl_easy_perform(curl);
  if (state != NULL && state->current.active) {
    state->current.curl_code = (long)result;
    state->current.has_curl_code = 1;
    emit_hop(state);
  }
  return result;
}

void curl_easy_cleanup(CURL *curl) {
  pthread_once(&symbols_once, resolve_symbols);
  if (real_curl_easy_cleanup == NULL) {
    return;
  }
  pthread_mutex_lock(&handles_mutex);
  struct handle_state **cursor = &handles;
  while (*cursor != NULL && (*cursor)->curl != curl) {
    cursor = &(*cursor)->next;
  }
  struct handle_state *state = *cursor;
  if (state != NULL) {
    *cursor = state->next;
  }
  pthread_mutex_unlock(&handles_mutex);
  if (state != NULL) {
    emit_hop(state);
    free(state);
  }
  real_curl_easy_cleanup(curl);
}
