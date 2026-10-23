defmodule ExMCP.Client.PushTransportTest do
  @moduledoc """
  What a custom push transport can rely on: the optional `ExMCP.Transport`
  callbacks that follow the client's lifecycle (deadlines, the negotiated
  protocol version, requests the client gives up on), request-scoped
  `{:transport_request_event, source, request_id, event}` messages, and the
  modern era (the `server/discover` probe, its refusals, cancellation by
  closing a request, and the request headers).
  """

  use ExUnit.Case, async: true

  alias ExMCP.Client
  alias ExMCP.Error.TransportError
  alias ExMCP.Internal.Headers
  alias ExMCP.Transport.HTTP.RequestHeaders

  @moduletag :capture_log

  doctest ExMCP.Transport, only: [modern_version?: 1]
  doctest ExMCP.Transport.HTTP.RequestHeaders

  defmodule Transport do
    @moduledoc """
    A push transport driven by the test process. Its connection is a process
    linked to the client; every message sent is reported to the test, which
    answers by sending the client transport events in the connection's name.

    The establishing exchanges are pulled. `initialize` is answered with a
    result, a JSON-RPC `:initialize_error`, or a `:handshake_error` from the
    transport; `server/discover` as `:discover` says: `:modern` answers it,
    `{:reject, status, error}` rejects it with an HTTP status and a
    JSON-RPC error body in a detail map, `{:refuse, reason}` fails it with
    `reason`.
    """

    @behaviour ExMCP.Transport

    defstruct [
      :connection,
      :test_pid,
      :handshake_error,
      :initialize_error,
      :discover,
      pull: nil,
      deadline: nil,
      version: nil
    ]

    @impl true
    def connect(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)

      connection =
        spawn_link(fn ->
          receive do
            :close -> :ok
          end
        end)

      send(test_pid, {:connected, connection})

      {:ok,
       %__MODULE__{
         connection: connection,
         test_pid: test_pid,
         handshake_error: Keyword.get(opts, :handshake_error),
         initialize_error: Keyword.get(opts, :initialize_error),
         discover: Keyword.get(opts, :discover)
       }}
    end

    @impl true
    def send_message(json, state) do
      message = Jason.decode!(json)

      send(
        state.test_pid,
        {:sent, state.connection, message, Map.take(state, [:deadline, :version])}
      )

      case message do
        %{"method" => "initialize", "id" => id} ->
          {:ok, %{state | pull: initialize_reply(state, id)}}

        %{"method" => "server/discover", "id" => id} ->
          {:ok, %{state | pull: discover_reply(state.discover, id)}}

        _other ->
          {:ok, state}
      end
    end

    # Only the establishing exchanges are pulled; everything after is pushed.
    @impl true
    def receive_message(%__MODULE__{pull: {:ok, response}} = state),
      do: {:ok, response, %{state | pull: nil}}

    def receive_message(%__MODULE__{pull: {:error, reason}}), do: {:error, reason}
    def receive_message(_state), do: {:error, :closed}

    @impl true
    def subscribe(_client, state) do
      send(state.test_pid, {:subscribed, state.connection, state.version})
      {:ok, state}
    end

    @impl true
    def close(state) do
      send(state.test_pid, {:closed, state.connection, state.deadline})
      send(state.connection, :close)
      :ok
    end

    @impl true
    def connected?(state), do: Process.alive?(state.connection)

    @impl true
    def linked_processes(state), do: [state.connection]

    @impl true
    def put_deadline(state, deadline), do: %{state | deadline: deadline}

    @impl true
    def deadline(state) do
      send(state.test_pid, {:deadline_read, state.connection})
      state.deadline
    end

    @impl true
    def set_protocol_version(state, version) do
      send(state.test_pid, {:version_set, state.connection, version})
      %{state | version: version}
    end

    @impl true
    def cancel_request(state, request_id) do
      send(state.test_pid, {:cancelled, state.connection, request_id})
      state
    end

    defp initialize_reply(%__MODULE__{handshake_error: reason}, _id) when reason != nil,
      do: {:error, reason}

    defp initialize_reply(%__MODULE__{initialize_error: error}, id) when error != nil,
      do: {:ok, json_rpc_error(id, error)}

    defp initialize_reply(_state, id) do
      {:ok,
       Jason.encode!(%{
         "jsonrpc" => "2.0",
         "id" => id,
         "result" => %{
           "protocolVersion" => "2025-06-18",
           "capabilities" => %{"tools" => %{}},
           "serverInfo" => %{"name" => "push-transport", "version" => "1"}
         }
       })}
    end

    defp discover_reply(:modern, id) do
      result = %{
        "resultType" => "complete",
        "supportedVersions" => ["2026-07-28"],
        "capabilities" => %{"tools" => %{}},
        "ttlMs" => 60_000,
        "cacheScope" => "private",
        "_meta" => %{
          "io.modelcontextprotocol/serverInfo" => %{"name" => "push-transport", "version" => "1"}
        }
      }

      {:ok, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})}
    end

    defp discover_reply({:reject, status, error}, id),
      do:
        {:error, {:http_error, status, %{body: json_rpc_error(id, error), www_authenticate: []}}}

    defp discover_reply({:refuse, reason}, _id), do: {:error, reason}

    defp json_rpc_error(id, error),
      do: Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "error" => error})
  end

  defmodule ClientHandler do
    @behaviour ExMCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :test_pid)}

    @impl true
    def handle_progress(request_id, params, test_pid) do
      send(test_pid, {:client_progress, request_id, params})
      {:ok, test_pid}
    end

    @impl true
    def handle_log_message(request_id, params, test_pid) do
      send(test_pid, {:client_log, request_id, params})
      {:ok, test_pid}
    end

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "not supported", state}
  end

  test "a handshake the transport saw refused fails start_link with the reason intact" do
    Process.flag(:trap_exit, true)

    challenge =
      ~s(Bearer resource_metadata="https://auth.example/.well-known/oauth-protected-resource")

    refusal = {:http_error, 401, %{www_authenticate: [challenge]}}

    assert {:error, {:transport_connect_failed, ^refusal}} =
             Client.start_link(
               transport: Transport,
               test_pid: self(),
               handshake_error: refusal,
               protocol_mode: :legacy_only,
               health_check_interval: nil,
               reconnect: false
             )
  end

  test "the transport adopts the negotiated version before notifications/initialized" do
    {_client, connection} = start_client()

    assert_receive {:sent, ^connection, %{"method" => "initialize"}, %{version: nil}}

    assert_receive {:sent, ^connection, %{"method" => "notifications/initialized"},
                    %{version: "2025-06-18"}}

    assert_receive {:subscribed, ^connection, "2025-06-18"}
    assert_received {:version_set, ^connection, "2025-06-18"}
    refute_received {:version_set, ^connection, _version}
  end

  test "a request with a timeout is sent under its deadline, cleared once it is sent" do
    {client, connection} = start_client()
    flush_deadline_reads(connection)
    sent_at = System.monotonic_time(:millisecond)

    task =
      Task.async(fn -> Client.call_tool(client, "echo", %{}, timeout: 2_000, format: :map) end)

    assert_receive {:deadline_read, ^connection}

    assert_receive {:sent, ^connection, %{"method" => "tools/call", "id" => id},
                    %{deadline: deadline}}

    assert is_integer(deadline)
    assert deadline >= sent_at + 2_000
    assert deadline <= System.monotonic_time(:millisecond) + 2_000
    assert %{transport_state: %Transport{deadline: nil}} = :sys.get_state(client)

    send(client, {:transport_event, result(id, %{"content" => []})})
    assert {:ok, %{"content" => []}} = Task.await(task)
  end

  test "close/1 runs under the client's cleanup deadline" do
    {client, connection} = start_client()
    stopped_at = System.monotonic_time(:millisecond)

    Client.stop(client)

    assert_receive {:closed, ^connection, deadline}
    assert is_integer(deadline)
    assert deadline >= stopped_at + 1_000
  end

  test "a request that times out is given up on through cancel_request/2" do
    {client, connection} = start_client()

    assert {:error, :timeout} = Client.call_tool(client, "hold", %{}, timeout: 50, format: :map)

    assert_receive {:sent, ^connection, %{"method" => "tools/call", "id" => id}, _transport}
    assert_receive {:cancelled, ^connection, ^id}, 2_000
    assert [] = Client.get_pending_requests(client)
  end

  describe "request-scoped events" do
    test "messages reach the request they belong to, and its response answers it" do
      {client, connection} = start_client()

      task =
        Task.async(fn ->
          Client.call_tool(client, "slow", %{},
            progress_token: "slow-1",
            timeout: 2_000,
            format: :map
          )
        end)

      assert_receive {:sent, ^connection, %{"method" => "tools/call", "id" => id}, _transport}

      progress = %{"progressToken" => "slow-1", "progress" => 1, "total" => 2}

      request_event(
        client,
        connection,
        id,
        {:message, notification("notifications/progress", progress)}
      )

      log = %{"level" => "info", "data" => "halfway"}

      request_event(
        client,
        connection,
        id,
        {:message, notification("notifications/message", log)}
      )

      assert_receive {:client_progress, ^id, ^progress}, 1_000
      assert_receive {:client_log, ^id, ^log}, 1_000

      request_event(client, connection, id, {:message, result(id, %{"content" => []})})
      assert {:ok, %{"content" => []}} = Task.await(task)
    end

    test "a server request on a request's exchange is answered, even without params" do
      {client, connection} = start_client()

      task =
        Task.async(fn -> Client.call_tool(client, "slow", %{}, timeout: 2_000, format: :map) end)

      assert_receive {:sent, ^connection, %{"method" => "tools/call", "id" => id}, _transport}

      ping = %{"jsonrpc" => "2.0", "id" => "server-ping", "method" => "ping"}
      request_event(client, connection, id, {:message, ping})

      assert_receive {:sent, ^connection, %{"id" => "server-ping", "result" => %{}}, _transport},
                     1_000

      request_event(client, connection, id, {:message, result(id, %{"content" => []})})
      assert {:ok, _result} = Task.await(task)
    end

    test "an ambiguous failure of a tool call is not reissued under safe_only" do
      {client, connection} = start_client()

      task =
        Task.async(fn ->
          Client.call_tool(client, "charge", %{},
            timeout: 2_000,
            http_stream_retry: :safe_only,
            http_stream_retry_delay: 0,
            format: :map
          )
        end)

      assert_receive {:sent, ^connection, %{"method" => "tools/call", "id" => id}, _transport}
      request_event(client, connection, id, {:error, :econnreset})

      assert {:error,
              %TransportError{
                transport: Transport,
                reason: :outcome_unknown,
                details: %{
                  attempts: 1,
                  retry_mode: :safe_only,
                  cause: %{cause: :econnreset, delivery: :ambiguous}
                }
              }} = Task.await(task)

      refute_receive {:sent, ^connection, %{"method" => "tools/call"}, _transport}, 100
    end

    test "an ambiguous failure is reissued once, with a new id, under at_least_once" do
      {client, connection} = start_client()

      task =
        Task.async(fn ->
          Client.call_tool(client, "lookup", %{},
            timeout: 2_000,
            http_stream_retry_delay: 0,
            format: :map
          )
        end)

      assert_receive {:sent, ^connection, %{"method" => "tools/call", "id" => first}, _transport}
      request_event(client, connection, first, {:error, :econnreset})

      assert_receive {:sent, ^connection, %{"method" => "tools/call", "id" => second},
                      _transport},
                     1_000

      refute second == first
      request_event(client, connection, second, {:message, result(second, %{"content" => []})})
      assert {:ok, %{"content" => []}} = Task.await(task)
    end

    test "a failure that shows how the server answered fails the request, unreissued" do
      {client, connection} = start_client()

      task =
        Task.async(fn ->
          Client.call_tool(client, "charge", %{},
            timeout: 2_000,
            http_stream_retry_delay: 0,
            format: :map
          )
        end)

      assert_receive {:sent, ^connection, %{"method" => "tools/call", "id" => id}, _transport}
      request_event(client, connection, id, {:error, {:http_error, 400}})

      assert {:error,
              %TransportError{
                transport: Transport,
                reason: :response_stream_invalid,
                details: %{cause: {:http_error, 400}, delivery: :not_retryable}
              } = error} = Task.await(task)

      assert Client.delivery_outcome(error) == :unknown
      refute_receive {:sent, ^connection, %{"method" => "tools/call"}, _transport}, 100
      assert %{connection_status: :ready} = :sys.get_state(client)
    end

    test "an error status with its detail is definite, so even a safe read is not reissued" do
      {client, connection} = start_client()
      detail = %{www_authenticate: [~s(Bearer error="insufficient_scope", scope="a b")]}

      task =
        Task.async(fn ->
          Client.list_tools(client,
            timeout: 2_000,
            http_stream_retry: :safe_only,
            http_stream_retry_delay: 0
          )
        end)

      assert_receive {:sent, ^connection, %{"method" => "tools/list", "id" => id}, _transport}
      request_event(client, connection, id, {:error, {:http_error, 403, detail}})

      assert {:error,
              %TransportError{
                reason: :response_stream_invalid,
                details: %{cause: {:http_error, 403, ^detail}, delivery: :not_retryable}
              }} = Task.await(task)

      refute_receive {:sent, ^connection, %{"method" => "tools/list"}, _transport}, 100
    end

    test "a closed connection is closed, fails pending requests, and is replaced" do
      {client, connection} =
        start_client(reconnect: true, reconnect_backoff: [initial: 10, max: 10])

      monitor = Process.monitor(connection)

      task =
        Task.async(fn -> Client.call_tool(client, "slow", %{}, timeout: 2_000, format: :map) end)

      assert_receive {:sent, ^connection, %{"method" => "tools/call", "id" => id}, _transport}

      request_event(client, connection, id, {:closed, :session_expired})

      assert {:error, %ExMCP.Error{code: :connection_error}} = Task.await(task)
      assert_receive {:closed, ^connection, _deadline}
      assert_receive {:DOWN, ^monitor, :process, ^connection, _reason}

      replacement = await_replacement(client, connection)
      refute_received {:sent, ^replacement, %{"method" => "tools/call"}, _transport}
    end

    test "events from a replaced connection are ignored" do
      {client, connection} =
        start_client(reconnect: true, reconnect_backoff: [initial: 10, max: 10])

      request_event(client, connection, nil, {:closed, :session_expired})
      replacement = await_replacement(client, connection)

      task =
        Task.async(fn -> Client.call_tool(client, "echo", %{}, timeout: 2_000, format: :map) end)

      assert_receive {:sent, ^replacement, %{"method" => "tools/call", "id" => id}, _transport}

      stale = result(id, %{"content" => [%{"type" => "text", "text" => "stale"}]})
      request_event(client, connection, id, {:message, stale})
      request_event(client, connection, id, {:error, :econnreset})
      request_event(client, connection, id, {:closed, :stale})

      assert %{connection_status: :ready, transport_state: %Transport{connection: ^replacement}} =
               :sys.get_state(client)

      assert [^id] = Client.get_pending_requests(client)

      request_event(client, replacement, id, {:message, result(id, %{"content" => []})})
      assert {:ok, %{"content" => []}} = Task.await(task)
      refute_received {:closed, ^replacement, _deadline}
    end
  end

  describe "the modern era" do
    test "a discovered server settles modern without initialize, the version set before subscribe" do
      {client, connection} = start_client(protocol_mode: :prefer_modern, discover: :modern)

      assert_receive {:sent, ^connection,
                      %{
                        "method" => "server/discover",
                        "id" => _id,
                        "params" => %{
                          "_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}
                        }
                      }, %{version: nil}}

      assert_receive {:subscribed, ^connection, "2026-07-28"}
      assert_received {:version_set, ^connection, "2026-07-28"}
      refute_received {:version_set, ^connection, _version}
      refute_received {:sent, ^connection, %{"method" => "initialize"}, _transport}
      refute_received {:sent, ^connection, %{"method" => "notifications/initialized"}, _transport}
      assert {:ok, "2026-07-28"} = Client.negotiated_version(client)
    end

    for status <- [400, 404] do
      test "a probe rejected with HTTP #{status} and a JSON-RPC body falls back to initialize" do
        method_not_found = %{"code" => -32601, "message" => "Method not found"}

        {client, connection} =
          start_client(
            protocol_mode: :prefer_modern,
            discover: {:reject, unquote(status), method_not_found}
          )

        assert_receive {:sent, ^connection, %{"method" => "server/discover"}, _transport}
        assert_receive {:sent, ^connection, %{"method" => "initialize"}, %{version: nil}}
        assert_receive {:subscribed, ^connection, "2025-06-18"}
        assert_received {:version_set, ^connection, "2025-06-18"}
        refute_received {:version_set, ^connection, _version}
        assert {:ok, "2025-06-18"} = Client.negotiated_version(client)
      end
    end
  end

  describe "request headers for a custom transport" do
    test "a modern tools/call mirrors method, name and declared parameters, with no session" do
      tool_headers =
        ExMCP.Transport.HTTP.ToolHeaders.cache([
          %{
            "name" => "météo",
            "inputSchema" => %{
              "type" => "object",
              "properties" => %{"region" => %{"type" => "string", "x-mcp-header" => "Region"}}
            }
          }
        ])

      body =
        modern_request("tools/call", %{"name" => "météo", "arguments" => %{"region" => "eu"}})

      headers =
        RequestHeaders.for_body(body, "2026-07-28",
          session_id: "stale-session",
          tool_headers: tool_headers
        )

      assert Headers.get(headers, "mcp-protocol-version") == "2026-07-28"
      assert Headers.get(headers, "mcp-method") == "tools/call"
      assert Headers.get(headers, "mcp-name") == RequestHeaders.encode_value("météo")
      assert "=?base64?" <> _encoded = Headers.get(headers, "mcp-name")
      assert Headers.get(headers, "mcp-param-region") == "eu"
      refute Headers.get(headers, "mcp-session-id")
      refute Headers.get(headers, "content-type")
      refute Headers.get(headers, "accept")
    end

    test "the probe is a modern request" do
      body = modern_request("server/discover", %{})

      assert Enum.sort(RequestHeaders.for_body(body, "2025-06-18")) == [
               {"MCP-Protocol-Version", "2026-07-28"},
               {"Mcp-Method", "server/discover"}
             ]
    end

    test "a legacy request carries the given version and session, and no modern headers" do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "weather", "arguments" => %{}}
        })

      assert Enum.sort(RequestHeaders.for_body(body, "2025-06-18", session_id: "session-1")) == [
               {"MCP-Protocol-Version", "2025-06-18"},
               {"Mcp-Session-Id", "session-1"}
             ]
    end
  end

  defp start_client(opts \\ []) do
    opts = Keyword.merge([protocol_mode: :legacy_only], opts)
    {:ok, client} = Client.start_link(client_opts(opts))
    Process.unlink(client)
    on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)

    assert_receive {:connected, connection}
    {client, connection}
  end

  # Options for a client of the test transport, in the default protocol mode
  # (:prefer_modern) unless `opts` say otherwise.
  defp client_opts(opts) do
    Keyword.merge(
      [
        transport: Transport,
        test_pid: self(),
        protocol_mode: :prefer_modern,
        health_check_interval: nil,
        reconnect: false,
        handler: {ClientHandler, [test_pid: self()]}
      ],
      opts
    )
  end

  defp modern_request(method, params) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    })
  end

  # Establishing the connection reads the deadline too.
  defp flush_deadline_reads(connection) do
    receive do
      {:deadline_read, ^connection} -> flush_deadline_reads(connection)
    after
      0 -> :ok
    end
  end

  defp await_replacement(client, connection) do
    assert_receive {:connected, replacement}, 1_000
    refute replacement == connection

    # The reconnect completes in the client before it handles anything else.
    assert %{connection_status: :ready, transport_state: %Transport{connection: ^replacement}} =
             :sys.get_state(client)

    replacement
  end

  defp request_event(client, source, request_id, event),
    do: send(client, {:transport_request_event, source, request_id, event})

  defp notification(method, params),
    do: %{"jsonrpc" => "2.0", "method" => method, "params" => params}

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}
end
