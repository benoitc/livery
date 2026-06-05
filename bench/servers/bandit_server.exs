# Reference Bandit server for the cross-server benchmark.
#
# Mirrors the livery/cowboy reference handlers:
#   GET  /            -> 200 application/json {"ok":true}
#   GET  /bytes/<n>   -> 200 text/plain, n bytes
#   POST /echo        -> 200 application/json, the request body echoed
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
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST", request_path: "/echo"} = conn, _opts) do
    {:ok, body, conn} = read_body(conn, length: 16_000_000)
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  def call(%Plug.Conn{method: "GET", request_path: "/bytes/" <> n} = conn, _opts) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, String.duplicate("x", String.to_integer(n)))
  end

  def call(conn, _opts) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"ok":true}))
  end
end

{:ok, _} = Bandit.start_link([plug: BenchPlug, scheme: scheme, port: port] ++ extra)
IO.puts("READY bandit #{scheme} #{port}")
Process.sleep(:infinity)
