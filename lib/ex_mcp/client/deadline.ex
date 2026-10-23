defmodule ExMCP.Client.Deadline do
  @moduledoc false
  # Absolute deadlines in monotonic milliseconds, and the transports that can
  # hold one. `nil` means "no deadline".

  alias ExMCP.Transport.{HTTP, ReliabilityWrapper}
  alias ExMCP.Transport.HTTP.LegacySSE

  @type t :: integer() | nil

  # Time allowed to clean up a transport (ending an HTTP session with its
  # DELETE), whatever deadline the transport carried before: cleanup must
  # happen even when a deadline is what failed, and must not hang on a peer
  # that stopped answering.
  @cleanup_timeout 1_000

  @spec cleanup_timeout() :: pos_integer()
  def cleanup_timeout, do: @cleanup_timeout

  @doc "`transport_state` capped for cleanup: see `cleanup_timeout/0`."
  @spec for_cleanup(module() | nil, term()) :: term()
  def for_cleanup(transport_mod, transport_state),
    do: put_on_transport(transport_mod, transport_state, after_ms(@cleanup_timeout))

  @spec after_ms(timeout()) :: t()
  def after_ms(:infinity), do: nil
  def after_ms(ms) when is_integer(ms), do: now() + ms

  @spec earliest(t(), t()) :: t()
  def earliest(nil, deadline), do: deadline
  def earliest(deadline, nil), do: deadline
  def earliest(a, b), do: min(a, b)

  @spec expired?(t()) :: boolean()
  def expired?(nil), do: false
  def expired?(deadline), do: now() >= deadline

  @doc "The time left before `deadline`, never negative."
  @spec remaining(t()) :: timeout()
  def remaining(nil), do: :infinity
  def remaining(deadline), do: max(deadline - now(), 0)

  @doc "`timeout`, shortened so it ends no later than `deadline`."
  @spec cap(timeout(), t()) :: timeout()
  def cap(timeout, nil), do: timeout
  def cap(:infinity, deadline), do: remaining(deadline)
  def cap(timeout, deadline), do: min(timeout, remaining(deadline))

  @doc """
  Caps the synchronous exchanges `transport_mod` makes with `transport_state`
  at `deadline` (or removes the cap with nil). Of the built-in transports only
  HTTP (Streamable HTTP and the legacy HTTP+SSE POST) sends synchronously from
  the calling process. A custom transport takes the deadline through its
  optional `c:ExMCP.Transport.put_deadline/2`; any other is returned unchanged
  and is bounded by its receive timeouts instead.
  """
  @spec put_on_transport(module() | nil, term(), t()) :: term()
  def put_on_transport(HTTP, %HTTP{} = state, deadline), do: HTTP.put_deadline(state, deadline)

  def put_on_transport(LegacySSE, %LegacySSE{} = state, deadline),
    do: %{state | deadline: deadline}

  def put_on_transport(ReliabilityWrapper, %ReliabilityWrapper{} = state, deadline) do
    %{
      state
      | wrapped_state: put_on_transport(state.wrapped_module, state.wrapped_state, deadline)
    }
  end

  def put_on_transport(transport_mod, transport_state, deadline) do
    if function_exported?(transport_mod, :put_deadline, 2),
      do: transport_mod.put_deadline(transport_state, deadline),
      else: transport_state
  end

  @doc "The deadline currently held by `transport_state`, if any."
  @spec on_transport(module() | nil, term()) :: t()
  def on_transport(HTTP, %HTTP{deadline: deadline}), do: deadline

  def on_transport(LegacySSE, %LegacySSE{deadline: deadline}), do: deadline

  def on_transport(ReliabilityWrapper, %ReliabilityWrapper{} = state),
    do: on_transport(state.wrapped_module, state.wrapped_state)

  def on_transport(transport_mod, transport_state) do
    if function_exported?(transport_mod, :deadline, 1),
      do: transport_mod.deadline(transport_state),
      else: nil
  end

  defp now, do: System.monotonic_time(:millisecond)
end
