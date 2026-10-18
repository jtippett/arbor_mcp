defmodule ExMCP.Client.ReliabilityCleanupTest do
  use ExUnit.Case, async: true

  alias ExMCP.{Client, TestHelpers}
  alias ExMCP.Transport.{ReliabilityWrapper, Stdio}

  test "a dead reliability component cannot skip closing the wrapped stdio child" do
    {client, wrapper} = start_client(circuit_breaker: [failure_threshold: 3])
    child = wrapper.wrapped_state
    assert os_alive?(child.os_pid)

    # The client is linked to the component, so its death reaches the client
    # as a transport link exit and the client abandons the transport.
    Process.exit(wrapper.circuit_breaker_pid, :kill)

    TestHelpers.wait_until(fn ->
      match?({:ok, %{connection_status: :disconnected}}, Client.get_status(client))
    end)

    refute Stdio.connected?(child)
    TestHelpers.wait_until(fn -> not os_alive?(child.os_pid) end, timeout: 2_000)
    assert Process.alive?(client)
  end

  # A client whose transport is a stdio child behind a ReliabilityWrapper,
  # both created inside the client process so the client owns the port and
  # is linked to the reliability components, as a real connection is.
  defp start_client(reliability_opts) do
    {:ok, client} =
      Client.start_link(
        transport: :test,
        _skip_connect: true,
        reconnect: false,
        health_check_interval: nil
      )

    on_exit(fn ->
      try do
        if Process.alive?(client), do: Client.stop(client)
      catch
        :exit, _reason -> :ok
      end
    end)

    shell = System.find_executable("sh") || flunk("sh executable required")

    state =
      :sys.replace_state(client, fn state ->
        {:ok, transport} = Stdio.connect(command: [shell, "-c", "exec cat"])
        {:ok, wrapper} = ReliabilityWrapper.wrap(Stdio, transport, reliability_opts)

        %{
          state
          | transport_mod: ReliabilityWrapper,
            transport_state: wrapper,
            connection_status: :ready
        }
      end)

    {client, state.transport_state}
  end

  # A child that has exited but is not yet reaped is a zombie, which `kill -0`
  # still reports as alive: count it as gone.
  defp os_alive?(os_pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", "#{os_pid}"], stderr_to_stdout: true) do
      {stat, 0} -> not String.starts_with?(String.trim(stat), "Z")
      {_output, _not_found} -> false
    end
  end
end
