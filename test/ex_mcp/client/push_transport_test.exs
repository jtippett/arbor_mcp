defmodule ExMCP.Client.PushTransportTest do
  @moduledoc """
  What a custom push transport can rely on: the optional `ExMCP.Transport`
  callbacks that follow the client's lifecycle (deadlines, the negotiated
  protocol version, requests the client gives up on), and request-scoped
  `{:transport_request_event, source, request_id, event}` messages.
  """

  use ExUnit.Case, async: true

  alias ExMCP.Client
  alias ExMCP.Error.TransportError

  @moduletag :capture_log

  defmodule Transport do
    @moduledoc """
    A push transport driven by the test process. Its connection is a process
    linked to the client; every message sent is reported to the test, which
    answers by sending the client transport events in the connection's name.
    """

    @behaviour ExMCP.Transport

    defstruct [:connection, :test_pid, :handshake, deadline: nil, version: nil]

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
      {:ok, %__MODULE__{connection: connection, test_pid: test_pid}}
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
          {:ok, %{state | handshake: initialize_response(id)}}

        _other ->
          {:ok, state}
      end
    end

    # Only the handshake is pulled; everything after it is pushed.
    @impl true
    def receive_message(%__MODULE__{handshake: nil}), do: {:error, :closed}
    def receive_message(state), do: {:ok, state.handshake, %{state | handshake: nil}}

    @impl true
    def subscribe(_client, state), do: {:ok, state}

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
    def set_protocol_version(state, version), do: %{state | version: version}

    @impl true
    def cancel_request(state, request_id) do
      send(state.test_pid, {:cancelled, state.connection, request_id})
      state
    end

    defp initialize_response(id) do
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "push-transport", "version" => "1"}
        }
      })
    end
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

  test "the transport adopts the negotiated version before notifications/initialized" do
    {_client, connection} = start_client()

    assert_receive {:sent, ^connection, %{"method" => "initialize"}, %{version: nil}}

    assert_receive {:sent, ^connection, %{"method" => "notifications/initialized"},
                    %{version: "2025-06-18"}}
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

  defp start_client(opts \\ []) do
    opts =
      Keyword.merge(
        [
          transport: Transport,
          test_pid: self(),
          protocol_mode: :legacy_only,
          health_check_interval: nil,
          reconnect: false,
          handler: {ClientHandler, [test_pid: self()]}
        ],
        opts
      )

    {:ok, client} = Client.start_link(opts)
    Process.unlink(client)
    on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)

    assert_receive {:connected, connection}
    {client, connection}
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
