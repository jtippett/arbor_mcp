defmodule ExMCP.Client.LegacyHttpSseTest do
  use ExUnit.Case, async: false

  alias ExMCP.Client
  alias ExMCP.Client.ConnectionManager
  alias ExMCP.HttpPlug
  alias ExMCP.Transport.HTTP.LegacySSE

  defmodule Handler do
    use ExMCP.Server.Handler
    use ExMCP.Server.DSL, name: "legacy-sse", version: "1.0.0"

    tool "echo", "Echo a message" do
      input_schema(%{
        type: "object",
        properties: %{
          message: %{type: "string"}
        },
        required: ["message"]
      })

      run(fn %{"message" => message}, state ->
        {:ok, %{content: [%{"type" => "text", "text" => "Echo: #{message}"}]}, state}
      end)
    end
  end

  defmodule PathRecorder do
    def init(opts) do
      owner = Keyword.fetch!(opts, :owner)
      {owner, HttpPlug.init(Keyword.delete(opts, :owner))}
    end

    def call(conn, {owner, plug_opts}) do
      send(owner, {:http_request, conn.method, conn.request_path})
      HttpPlug.call(conn, plug_opts)
    end
  end

  defmodule HoldingPosts do
    # Serves the legacy endpoint, except that the :hold_from-th POST and every
    # later one are held without a reply until the listener shuts down.
    def init(opts) do
      {owner, opts} = Keyword.pop!(opts, :owner)
      {posts, opts} = Keyword.pop!(opts, :posts)
      {hold_from, opts} = Keyword.pop!(opts, :hold_from)
      {owner, posts, hold_from, HttpPlug.init(opts)}
    end

    def call(%Plug.Conn{method: "POST"} = conn, {owner, posts, hold_from, plug_opts}) do
      :ok = :counters.add(posts, 1, 1)

      if :counters.get(posts, 1) >= hold_from do
        send(owner, {:post_held, :counters.get(posts, 1)})
        never = make_ref()

        receive do
          ^never -> conn
        end
      else
        HttpPlug.call(conn, plug_opts)
      end
    end

    def call(conn, {_owner, _posts, _hold_from, plug_opts}), do: HttpPlug.call(conn, plug_opts)
  end

  # Far below the transport's request timeout used with it, and loose enough
  # for a loaded CI host.
  @bound 4_000

  setup do
    port = free_port()
    ranch_ref = {:legacy_http_sse_test, System.unique_integer([:positive])}

    {:ok, _pid} =
      Plug.Cowboy.http(
        PathRecorder,
        [
          owner: self(),
          handler: Handler,
          protocol_mode: :legacy_only,
          legacy_http_sse: true,
          sse_mode: :stream,
          path: "/mcp"
        ],
        ip: {127, 0, 0, 1},
        port: port,
        ref: ranch_ref
      )

    on_exit(fn ->
      try do
        Plug.Cowboy.shutdown(ranch_ref)
      catch
        :exit, _reason -> :ok
      end
    end)

    {:ok, port: port}
  end

  test "start_link with transport :sse initializes and calls a tool", %{port: port} do
    {:ok, client} =
      Client.start_link(
        transport: :sse,
        url: "http://127.0.0.1:#{port}",
        health_check_interval: nil
      )

    on_exit(fn ->
      try do
        if Process.alive?(client), do: Client.disconnect(client)
      catch
        :exit, _reason -> :ok
      end
    end)

    assert_receive {:http_request, "GET", "/sse"}, 2_000
    refute_received {:http_request, "GET", "/mcp"}

    assert {:ok, %{"tools" => tools}} = Client.list_tools(client, format: :map)
    assert Enum.any?(tools, fn tool -> tool["name"] == "echo" end)

    assert {:ok, result} =
             Client.call_tool(client, "echo", %{"message" => "hello"}, format: :map)

    text = result["content"] |> hd() |> Map.get("text")
    assert text == "Echo: hello"

    assert_received {:http_request, "POST", "/message"}
    refute_received {:http_request, "GET", "/mcp"}
  end

  test "sse_path override hits the configured GET path, not the MCP endpoint", %{port: _port} do
    custom_port = free_port()
    ranch_ref = {:legacy_http_sse_custom, System.unique_integer([:positive])}

    {:ok, _pid} =
      Plug.Cowboy.http(
        PathRecorder,
        [
          owner: self(),
          handler: Handler,
          protocol_mode: :legacy_only,
          legacy_http_sse: true,
          legacy_http_sse_path: "/events",
          legacy_http_sse_post_path: "/inbox",
          sse_mode: :stream,
          path: "/mcp"
        ],
        ip: {127, 0, 0, 1},
        port: custom_port,
        ref: ranch_ref
      )

    on_exit(fn ->
      try do
        Plug.Cowboy.shutdown(ranch_ref)
      catch
        :exit, _reason -> :ok
      end
    end)

    {:ok, client} =
      Client.start_link(
        transport: :sse,
        url: "http://127.0.0.1:#{custom_port}",
        sse_path: "/events",
        health_check_interval: nil
      )

    on_exit(fn ->
      try do
        if Process.alive?(client), do: Client.disconnect(client)
      catch
        :exit, _reason -> :ok
      end
    end)

    assert_receive {:http_request, "GET", "/events"}, 2_000
    refute_received {:http_request, "GET", "/sse"}
    refute_received {:http_request, "GET", "/mcp"}

    assert {:ok, %{"tools" => tools}} = Client.list_tools(client, format: :map)
    assert Enum.any?(tools, fn tool -> tool["name"] == "echo" end)
    assert_received {:http_request, "POST", "/inbox"}
  end

  test "transport :sse is wired as LegacySSE and is not use_sse Streamable HTTP" do
    assert {:ok, [transports: [{LegacySSE, opts}]]} =
             ConnectionManager.prepare_transport_config(
               transport: :sse,
               url: "http://127.0.0.1:4000"
             )

    assert opts[:url] == "http://127.0.0.1:4000"
    refute Keyword.get(opts, :use_sse, false)

    assert {:ok, [transports: [{ExMCP.Transport.HTTP, http_opts}]]} =
             ConnectionManager.prepare_transport_config(
               transport: :http,
               url: "http://127.0.0.1:4000/mcp",
               use_sse: true
             )

    assert http_opts[:use_sse] == true
    assert http_opts[:url] == "http://127.0.0.1:4000/mcp"
  end

  describe "deadlines on the synchronous legacy POST" do
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    test "an initialize POST that never answers ends at :handshake_timeout" do
      port = start_holding_server(hold_from: 1)

      {elapsed, result} =
        timed(fn ->
          Client.start_link(
            transport: :sse,
            url: "http://127.0.0.1:#{port}",
            handshake_timeout: 300,
            request_timeout: 8_000,
            health_check_interval: nil,
            reconnect: false
          )
        end)

      assert_received {:post_held, 1}
      assert {:error, :handshake_timeout} = result
      assert elapsed < @bound
    end

    test "an initialize POST that never answers ends at :establish_timeout" do
      port = start_holding_server(hold_from: 1)

      {elapsed, result} =
        timed(fn ->
          Client.start_link(
            transport: :sse,
            url: "http://127.0.0.1:#{port}",
            handshake_timeout: 30_000,
            establish_timeout: 400,
            request_timeout: 8_000,
            health_check_interval: nil,
            reconnect: false
          )
        end)

      assert_received {:post_held, 1}
      assert {:error, :establish_timeout} = result
      assert elapsed < @bound
    end

    test "a request POST that never answers frees the client at the caller's deadline" do
      # POST 1 is initialize and POST 2 notifications/initialized.
      port = start_holding_server(hold_from: 3)

      {:ok, client} =
        Client.start_link(
          transport: :sse,
          url: "http://127.0.0.1:#{port}",
          request_timeout: 8_000,
          health_check_interval: nil,
          reconnect: false
        )

      {elapsed, result} =
        timed(fn ->
          request = Client.list_tools(client, timeout: 300)
          # Answered only once the client is out of the held POST.
          {request, Client.get_status(client, timeout: @bound)}
        end)

      assert_received {:post_held, 3}
      assert {{:error, _reason}, {:ok, %{connection_status: :ready}}} = result
      assert elapsed < @bound
    end
  end

  defp start_holding_server(opts) do
    port = free_port()
    ranch_ref = {:legacy_http_sse_holding, System.unique_integer([:positive])}

    {:ok, _pid} =
      Plug.Cowboy.http(
        HoldingPosts,
        [
          owner: self(),
          posts: :counters.new(1, []),
          hold_from: Keyword.fetch!(opts, :hold_from),
          handler: Handler,
          protocol_mode: :legacy_only,
          legacy_http_sse: true,
          sse_mode: :stream,
          path: "/mcp"
        ],
        ip: {127, 0, 0, 1},
        port: port,
        ref: ranch_ref
      )

    on_exit(fn ->
      try do
        Plug.Cowboy.shutdown(ranch_ref)
      catch
        :exit, _reason -> :ok
      end
    end)

    port
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
