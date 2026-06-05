# Reference Bandit server for the cross-server benchmark.
#
# Serves the same endpoint as the livery/cowboy reference handlers:
# GET / -> 200 application/json {"ok":true} over HTTP/1.1.
#
# Run: elixir bench/servers/bandit_server.exs <port>
# Pulls Bandit (and Plug, Thousand Island) via Mix.install on first run,
# which needs network access; compiled artifacts are cached afterwards.

port =
  case System.argv() do
    [p | _] -> String.to_integer(p)
    [] -> 9103
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

{:ok, _} = Bandit.start_link(plug: BenchPlug, scheme: :http, port: port)
IO.puts("READY bandit http #{port}")
Process.sleep(:infinity)
