# How to handle file uploads (multipart/form-data)

## Problem

A client POSTs `multipart/form-data` (a browser form with files, or a
multimodal request) and you need the fields and uploaded files without
buffering the whole request in memory.

## Solution

Use `livery_multipart`. Pull parts one at a time and stream each part's
body, so a large upload never sits in RAM:

```erlang
upload(Req) ->
    {ok, MP0} = livery_multipart:new(Req),
    loop(MP0).

loop(MP) ->
    case livery_multipart:next_part(MP, 5000) of
        {part, #{name := Name, filename := File}, MP1} ->
            {ok, MP2} = consume(MP1, Name, File),
            loop(MP2);
        {done, _MP1} ->
            livery_resp:text(200, <<"ok">>);
        {error, Reason, _MP1} ->
            livery_resp:text(400, atom_to_binary(element(1, {Reason, x})))
    end.

consume(MP, _Name, _File) ->
    case livery_multipart:read_part(MP, 5000) of
        {ok, Chunk, MP1} -> %% write Chunk to disk / forward / hash
            consume(MP1, _Name, _File);
        {done, MP1} -> {ok, MP1};
        {error, _, MP1} -> {ok, MP1}
    end.
```

`next_part/2` returns each part's `name`, `filename`, `content_type`,
and raw `headers` (parsed from `Content-Disposition`). `read_part/2`
streams that part's bytes; calling `next_part` again skips any unread
remainder.

## Small forms: read everything at once

When the parts are small, `read_all/1,2` collects them into memory under
the limits:

```erlang
{ok, Parts} = livery_multipart:read_all(Req),
%% Parts :: [#{name, filename, content_type, headers, body}]
```

## Limits

All buffering is bounded. Override the defaults via the options map on
`new/2` / `read_all/2`:

```erlang
livery_multipart:read_all(Req, #{
    max_parts => 50,             %% default 1000
    max_part_size => 5_242_880,  %% read_all per-part bytes; default 10 MiB
    max_header_bytes => 16_384,  %% per-part header block; default 64 KiB
    max_header_count => 32,      %% header fields per part; default 64
    max_body => 52_428_800,      %% total bytes consumed; default 100 MiB
    part_timeout => 5000         %% per read; default 5000 ms
}).
```

## Security: sanitize the filename

`filename` is returned exactly as the client sent it and the parser
never touches the filesystem. A hostile client can send
`../../etc/passwd`. If you write uploads to disk, confine the path
yourself (basename + a fixed directory); never join the raw `filename`
onto a path.

## See also

- Reference: `livery_multipart`, `livery_body`
- Recipe: [Parse form bodies](parse-form-bodies.md)
- Recipe: [Read a streaming request body](read-streaming-body.md)
