defmodule ExMCP.Client.PushTransportTest do
  @moduledoc """
  The optional `ExMCP.Transport` callbacks a custom push transport uses to
  follow the client's lifecycle: deadlines, the negotiated protocol version
  and requests the client gives up on.
  """

  use ExUnit.Case, async: true

  alias ExMCP.Client

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

  defp start_client(opts \\ []) do
    opts =
      Keyword.merge(
        [
          transport: Transport,
          test_pid: self(),
          protocol_mode: :legacy_only,
          health_check_interval: nil,
          reconnect: false
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

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}
end
