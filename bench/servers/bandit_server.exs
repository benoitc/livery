# Reference Bandit server for the cross-server benchmark.
#
# Serves the same endpoint as the livery/cowboy reference handlers:
# GET / -> 200 application/json {"ok":true}.
#
# Run:
#   elixir bench/servers/bandit_server.exs <port>                  # HTTP/1.1
#   elixir bench/servers/bandit_server.exs <port> <cert> <key>     # HTTPS (h2 via ALPN)
#
# Pulls Bandit (and Plug, Thousand Island) via Mix.install on first run,
# which needs network access; compiled artifacts are cached afterwards.

{port, scheme, extra} =
  case System.argv() do
    [p, cert, key] ->
      {String.to_integer(p), :https, [certfile: cert, keyfile: key]}

    [p | _] ->
      {String.to_integer(p), :http, []}

    [] ->
      {9103, :http, []}
  end

Mix.install([:bandit])

defmodule BenchPlug do
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, ~s({"ok":true}))
  end
end

{:ok, _} = Bandit.start_link([plug: BenchPlug, scheme: scheme, port: port] ++ extra)
IO.puts("READY bandit #{scheme} #{port}")
Process.sleep(:infinity)
