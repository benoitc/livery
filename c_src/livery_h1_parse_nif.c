/*
 * NIF wrapper for picohttpparser
 *
 * Provides fast HTTP/1.x request parsing for livery.
 */

#include <string.h>
#include "erl_nif.h"
#include "picohttpparser.h"

#define MAX_HEADERS 100
#define MAX_METHOD_LEN 16
#define MAX_PATH_LEN 8192

/* Atoms */
static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_more;
static ERL_NIF_TERM atom_method_too_long;
static ERL_NIF_TERM atom_uri_too_long;
static ERL_NIF_TERM atom_too_many_headers;
static ERL_NIF_TERM atom_bad_request;

static int load(ErlNifEnv* env, void** priv_data __attribute__((unused)),
                ERL_NIF_TERM load_info __attribute__((unused)))
{
    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    atom_more = enif_make_atom(env, "more");
    atom_method_too_long = enif_make_atom(env, "method_too_long");
    atom_uri_too_long = enif_make_atom(env, "uri_too_long");
    atom_too_many_headers = enif_make_atom(env, "too_many_headers");
    atom_bad_request = enif_make_atom(env, "bad_request");
    return 0;
}

static ERL_NIF_TERM make_binary(ErlNifEnv* env, const char* data, size_t len)
{
    ERL_NIF_TERM bin;
    unsigned char* buf = enif_make_new_binary(env, len, &bin);
    if (buf == NULL) {
        return enif_make_badarg(env);
    }
    memcpy(buf, data, len);
    return bin;
}

static ERL_NIF_TERM make_binary_upper(ErlNifEnv* env, const char* data, size_t len)
{
    ERL_NIF_TERM bin;
    unsigned char* buf = enif_make_new_binary(env, len, &bin);
    if (buf == NULL) {
        return enif_make_badarg(env);
    }
    /* Convert to uppercase while copying */
    for (size_t i = 0; i < len; i++) {
        unsigned char c = data[i];
        if (c >= 'a' && c <= 'z') {
            buf[i] = c - 32;
        } else {
            buf[i] = c;
        }
    }
    return bin;
}

static ERL_NIF_TERM make_header_name_lower(ErlNifEnv* env, const char* data, size_t len)
{
    ERL_NIF_TERM bin;
    unsigned char* buf = enif_make_new_binary(env, len, &bin);
    if (buf == NULL) {
        return enif_make_badarg(env);
    }
    /* Convert to lowercase while copying */
    for (size_t i = 0; i < len; i++) {
        unsigned char c = data[i];
        if (c >= 'A' && c <= 'Z') {
            buf[i] = c + 32;
        } else {
            buf[i] = c;
        }
    }
    return bin;
}

/* Trim leading and trailing whitespace from header value */
static ERL_NIF_TERM make_header_value_trimmed(ErlNifEnv* env, const char* data, size_t len)
{
    /* Skip leading whitespace */
    while (len > 0 && (data[0] == ' ' || data[0] == '\t')) {
        data++;
        len--;
    }
    /* Skip trailing whitespace */
    while (len > 0 && (data[len-1] == ' ' || data[len-1] == '\t')) {
        len--;
    }
    return make_binary(env, data, len);
}

/*
 * parse_request(Binary) -> {ok, Method, Path, Qs, Version, Headers, Rest} |
 *                          {more, Binary} |
 *                          {error, Reason}
 *
 * Version = {Major, Minor}
 * Headers = [{Name, Value}]
 */
static ERL_NIF_TERM parse_request_nif(ErlNifEnv* env,
                                      int argc __attribute__((unused)),
                                      const ERL_NIF_TERM argv[])
{
    ErlNifBinary input;

    if (!enif_inspect_binary(env, argv[0], &input)) {
        return enif_make_badarg(env);
    }

    const char* method;
    size_t method_len;
    const char* path;
    size_t path_len;
    int minor_version;
    struct phr_header headers[MAX_HEADERS];
    size_t num_headers = MAX_HEADERS;

    int pret = phr_parse_request(
        (const char*)input.data, input.size,
        &method, &method_len,
        &path, &path_len,
        &minor_version,
        headers, &num_headers,
        0  /* last_len - 0 for first parse */
    );

    if (pret == -2) {
        /* Need more data */
        return enif_make_tuple2(env, atom_more, argv[0]);
    }

    if (pret == -1) {
        /* Parse error */
        return enif_make_tuple2(env, atom_error, atom_bad_request);
    }

    /* Check limits */
    if (method_len > MAX_METHOD_LEN) {
        return enif_make_tuple2(env, atom_error, atom_method_too_long);
    }

    if (path_len > MAX_PATH_LEN) {
        return enif_make_tuple2(env, atom_error, atom_uri_too_long);
    }

    /* Split path into path and query string */
    const char* qs = NULL;
    size_t qs_len = 0;
    size_t path_only_len = path_len;

    for (size_t i = 0; i < path_len; i++) {
        if (path[i] == '?') {
            path_only_len = i;
            qs = path + i + 1;
            qs_len = path_len - i - 1;
            break;
        }
    }

    /* Build Method binary (uppercased) */
    ERL_NIF_TERM method_bin = make_binary_upper(env, method, method_len);

    /* Build Path binary (without query string) */
    ERL_NIF_TERM path_bin = make_binary(env, path, path_only_len);

    /* Build Query string binary */
    ERL_NIF_TERM qs_bin;
    if (qs != NULL) {
        qs_bin = make_binary(env, qs, qs_len);
    } else {
        unsigned char* buf = enif_make_new_binary(env, 0, &qs_bin);
        (void)buf;
    }

    /* Build Version tuple {1, Minor} */
    ERL_NIF_TERM version = enif_make_tuple2(env,
        enif_make_int(env, 1),
        enif_make_int(env, minor_version));

    /* Build Headers list [{Name, Value}] with lowercase names and trimmed values */
    ERL_NIF_TERM headers_list = enif_make_list(env, 0);
    for (int i = num_headers - 1; i >= 0; i--) {
        if (headers[i].name != NULL) {
            ERL_NIF_TERM name = make_header_name_lower(env, headers[i].name, headers[i].name_len);
            ERL_NIF_TERM value = make_header_value_trimmed(env, headers[i].value, headers[i].value_len);
            ERL_NIF_TERM header = enif_make_tuple2(env, name, value);
            headers_list = enif_make_list_cell(env, header, headers_list);
        }
    }

    /* Build Rest binary (unparsed data) */
    size_t rest_len = input.size - pret;
    ERL_NIF_TERM rest_bin = make_binary(env, (const char*)input.data + pret, rest_len);

    /* Return {ok, Method, Path, Qs, Version, Headers, Rest} */
    return enif_make_tuple7(env,
        atom_ok,
        method_bin,
        path_bin,
        qs_bin,
        version,
        headers_list,
        rest_bin);
}

static ErlNifFunc nif_funcs[] = {
    {"parse_request_nif", 1, parse_request_nif, 0}
};

ERL_NIF_INIT(livery_h1_parse_nif, nif_funcs, load, NULL, NULL, NULL)
