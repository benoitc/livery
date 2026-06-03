%% @doc Shared listen-address option translation.
%%
%% Every adapter accepts the same `ip'/`inet6' listen options; this
%% module turns them into the `[inet6 | {ip, Addr}]' socket option list
%% the wire libraries expect.
-module(livery_inet).

-export([socket_addr_opts/1]).

-doc """
Build inet listen options from the `ip'/`inet6' keys of a listen-opts map.

An IPv6 `ip' tuple (an 8-tuple) or `inet6 => true' selects the `inet6'
family; `ip' sets the bind address. Returns a list suitable for the
`gen_tcp'/`ssl' listen options or quic's `extra_socket_opts'. Returns
`[]' when neither key is set, so callers fall back to default binding.
""".
-spec socket_addr_opts(map()) -> [inet6 | {ip, inet:ip_address()}].
socket_addr_opts(Opts) ->
    IP = maps:get(ip, Opts, undefined),
    Family =
        case {IP, maps:get(inet6, Opts, false)} of
            {{_, _, _, _, _, _, _, _}, _} -> [inet6];
            {_, true} -> [inet6];
            _ -> []
        end,
    Addr =
        case IP of
            undefined -> [];
            _ -> [{ip, IP}]
        end,
    Family ++ Addr.
