defmodule ExMCP.Client.BatchTeardownTest do
  @moduledoc """
  A batch request still waiting for its responses when the connection ends
  is answered with per-request connection errors, and the client survives.

  Each batch member's pending entry points at the batch's id, which is an
  integer from `ExMCP.Internal.JSONRPC.generate_id/0`, so teardown must not
  assume it is a string.
  """

  use ExUnit.Case, async: true

  alias ExMCP.Client
  alias ExMCP.Error

  defmodule PushTransport do
    @moduledoc """
    Push-model transport: the handshake is answered synchronously, every
    other outbound message is reported to the test process, and nothing is
    ever answered, so a batch stays pending until the test ends the
    connection.
    """

    @behaviour ExMCP.Transport

    defstruct [:test_pid, :pending]

    @impl true
    def connect(opts), do: {:ok, %__MODULE__{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def send_message(message, %__MODULE__{} = state) do
      case Jason.decode!(message) do
        %{"method" => "initialize", "id" => id} ->
          {:ok, %{state | pending: initialize_response(id)}}

        decoded ->
          send(state.test_pid, {:sent, decoded})
          {:ok, state}
      end
    end

    @impl true
    def receive_message(%__MODULE__{pending: nil}), do: {:error, :closed}

    def receive_message(%__MODULE__{pending: response} = state),
      do: {:ok, response, %{state | pending: nil}}

    @impl true
    def close(_state), do: :ok

    @impl true
    def connected?(_state), do: true

    @impl true
    def subscribe(_pid, %__MODULE__{} = state), do: {:ok, state}

    @impl true
    def capabilities(_state), do: [:push]

    defp initialize_response(id) do
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "protocolVersion" => "2025-03-26",
          "capabilities" => %{"tools" => %{}, "prompts" => %{}},
          "serverInfo" => %{"name" => "batch-teardown", "version" => "1.0.0"}
        }
      })
    end
  end

  test "disconnect answers a pending batch instead of crashing the client" do
    client = start_client()
    batch = start_pending_batch(client)

    assert :ok = Client.disconnect(client)

    assert {:ok,
            [{:error, %Error{code: :connection_error}}, {:error, %Error{code: :connection_error}}]} =
             Task.await(batch)

    assert Process.alive?(client)
    assert {:ok, %{connection_status: :disconnected}} = Client.get_status(client)
  end

  test "transport loss answers a pending batch instead of crashing the client" do
    client = start_client()
    batch = start_pending_batch(client)

    send(client, {:transport_closed, :connection_lost})

    assert {:ok,
            [{:error, %Error{code: :connection_error}}, {:error, %Error{code: :connection_error}}]} =
             Task.await(batch)

    assert Process.alive?(client)
    assert {:ok, %{connection_status: :disconnected}} = Client.get_status(client)
  end

  defp start_client do
    {:ok, client} =
      Client.start_link(
        transport: PushTransport,
        test_pid: self(),
        protocol_mode: :legacy_only,
        protocol_version: "2025-03-26",
        health_check_interval: nil,
        reconnect: false
      )

    client
  end

  # Returns once both batch members were written and the batch is pending:
  # the batch call registers its pending entries in the same client callback
  # that writes them, before any later call is handled.
  defp start_pending_batch(client) do
    batch =
      Task.async(fn ->
        Client.batch_request(client, [{"tools/list", %{}}, {"prompts/list", %{}}])
      end)

    assert_receive {:sent, [%{"method" => "tools/list"}, %{"method" => "prompts/list"}]}, 1_000
    batch
  end
end
