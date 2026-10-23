defmodule ExMCP.Transport do
  @moduledoc """
  Behaviour definition for MCP transport implementations.

  A transport is responsible for sending and receiving MCP protocol messages
  over a specific communication channel. ExMCP includes implementations for
  the standard MCP transports and provides this behaviour for custom implementations.

  ## Built-in Transports

  ExMCP provides these standard transports:

  - **`:stdio`** - Standard I/O communication (MCP specification)
  - **`:http`** - HTTP with optional SSE streaming (MCP specification)
  - **`:sse`** - Deprecated MCP 2024-11-05 HTTP+SSE (`GET /sse` + `POST /message`)
  - **`:test`** - In-memory transport for testing
  - **`:beam`** - BEAM-local transport carrying MCP-shaped messages as Elixir terms.

  ## Using Transports

  Transports are specified when starting clients or servers:

      # stdio transport
      {:ok, client} = ExMCP.Client.start_link(
        transport: :stdio,
        command: ["python", "mcp-server.py"]
      )

      # HTTP transport
      {:ok, client} = ExMCP.Client.start_link(
        transport: :http,
        url: "https://api.example.com"
      )

  ## Push vs Pull Model

  Transports support two message delivery models:

  - **Pull (legacy):** Client calls `receive_message/1` in a loop via a receiver task.
    This is the default and works for all transports.

  - **Push (event-driven):** Client calls `subscribe/2` to register a handler pid.
    The transport pushes `{:transport_event, message}` messages directly to the handler.
    This eliminates the receiver task and is more efficient.

  Transports that implement `subscribe/2` should still implement `receive_message/1`
  for backwards compatibility.

  A push transport that runs each request's exchange separately (each HTTP
  POST in its own process, say) can also report events of one request; see
  `subscribe/2`.

  ## Custom Transport Implementation

  To implement a custom transport, create a module that implements
  all the callbacks defined in this behaviour:

      defmodule MyTransport do
        @behaviour ExMCP.Transport

        @impl true
        def connect(opts) do
          # Establish connection
          {:ok, state}
        end

        @impl true
        def send_message(message, state) do
          # Send the message
          {:ok, state}
        end

        @impl true
        def receive_message(state) do
          # Receive a message (blocking)
          {:ok, message, state}
        end

        @impl true
        def close(state) do
          # Clean up
          :ok
        end

        # Optional: enable push model
        @impl true
        def subscribe(pid, state) do
          # Start pushing {:transport_event, msg} to pid
          {:ok, %{state | subscriber: pid}}
        end
      end
  """

  @type state :: any()
  @type message :: String.t() | map() | list()
  @type opts :: keyword()

  @doc """
  Establishes a connection for the transport.

  Options are transport-specific. Should return `{:ok, state}`
  where state contains any necessary connection information.
  """
  @callback connect(opts()) :: {:ok, state()} | {:error, any()}

  @doc """
  Sends a message through the transport.

  The message will be a JSON-encoded string for wire transports, or an
  MCP-shaped map/list for local BEAM transports. Should return
  `{:ok, new_state}` on success.

  Synchronous request/response transports (e.g. HTTP POST without SSE
  streaming) may instead return `{:ok, new_state, response}` where
  `response` is the response body delivered inline — either a raw JSON
  string or an already-decoded map. Callers must be prepared to handle
  both the 2-tuple and 3-tuple success shapes; transports that deliver
  responses asynchronously (via `receive_message/1` or `subscribe/2`)
  should return the 2-tuple.
  """
  @callback send_message(message(), state()) ::
              {:ok, state()} | {:ok, state(), response :: binary() | map()} | {:error, any()}

  @doc """
  Receives a message from the transport.

  This should block until a message is available. Returns
  `{:ok, message, new_state}` where message is a JSON string or MCP-shaped term.

  Note: When `subscribe/2` is used, `receive_message/1` may not be called.
  Transports should still implement it for backwards compatibility.
  """
  @callback receive_message(state()) :: {:ok, message(), state()} | {:error, any()}

  @doc """
  Closes the transport connection.

  Should clean up any resources and return `:ok`.
  """
  @callback close(state()) :: :ok

  @doc """
  Optional callback to check if the transport is still connected.

  Default implementation always returns true.
  """
  @callback connected?(state()) :: boolean()

  @doc """
  Optional: Subscribe a process to receive transport events.

  When implemented, the transport pushes messages to the subscriber pid as:
  - `{:transport_event, message}` — a received message (JSON string or map)
  - `{:transport_closed, reason}` — transport connection closed
  - `{:transport_error, reason}` — transport error occurred

  This enables the push (event-driven) model, eliminating the need for a
  receiver task that polls `receive_message/1`.

  ## Request-scoped events

  A transport that knows which request an event belongs to can send
  `ExMCP.Client` `{:transport_request_event, source, request_id, event}`
  instead. `source` is the transport process the event comes from: the
  client drops an event whose `source` is not among the current
  `linked_processes/1`, so a late event from a connection it has replaced is
  harmless. `event` is one of:

  - `{:message, message}` - a decoded JSON-RPC message (a map) that arrived
    on the request's exchange: its response, or a server message sent before
    it. `notifications/progress` and `notifications/message` go to the
    client handler's `c:ExMCP.Client.Handler.handle_progress/3` and
    `c:ExMCP.Client.Handler.handle_log_message/3` with `request_id`; any
    other message is handled as if pushed with `{:transport_event, message}`.
  - `{:error, reason}` - the exchange failed and no response is coming. The
    pending request fails with an `ExMCP.Error.TransportError` whose
    `details.cause` is `reason`. A reason that shows how the server
    answered, an HTTP error status (`{:http_error, status}`) or a malformed
    or unfinished response (`:invalid_stream_message`, `:invalid_sse_json`,
    `:response_id_mismatch`, `:final_response_required`), gives
    `reason: :response_stream_invalid`, and the request is not reissued.
    Any other reason means the request may have reached the server, and
    gives `reason: :response_stream_broken` with
    `details.delivery: :ambiguous`. The client then reissues the request
    once under the default `http_stream_retry: :at_least_once`; under
    `http_stream_retry: :safe_only` it reissues only an operation that is
    safe to repeat, and fails any other with `reason: :outcome_unknown`
    (see `ExMCP.Client`).
  - `{:closed, reason}` - the connection is gone, as with
    `{:transport_closed, reason}`: the client closes the transport, fails
    every pending request with a connection error and reconnects if it is
    configured to.

  Returns `{:ok, new_state}` on success.
  """
  @callback subscribe(pid(), state()) :: {:ok, state()} | {:error, any()}

  @doc """
  Optional callback to declare transport capabilities.

  Returns a list of capability atoms that indicate special features
  supported by this transport. Clients can use this information to
  optimize their communication strategy.

  ## Capabilities

  - `:push` - Transport supports `subscribe/2` for event-driven message delivery
  - `:compression` - Transport supports message compression (future)
  - `:encryption` - Transport supports message encryption (future)

  ## Examples

      # Transport with push delivery
      def capabilities(_state), do: [:push]

      # Transport with no special capabilities (default)
      def capabilities(_state), do: []

  Default implementation returns an empty list (no special capabilities).
  """
  @callback capabilities(state()) :: [atom()]

  @doc """
  Optional: the processes and ports this transport has linked to the process
  that called `connect/1` or `subscribe/2` (for example a reader it
  `spawn_link`ed, or a port it opened).

  `ExMCP.Client` traps exits. An abnormal exit signal from one of these is
  treated as the transport failing (pending requests fail and the reconnect
  path takes over); an abnormal exit signal from any other linked process
  stops the client, exactly as it would stop a process that does not trap
  exits. A transport that links helpers to its caller without listing them
  here makes their crash stop the client.

  Default implementation returns an empty list.
  """
  @callback linked_processes(state()) :: [pid() | port()]

  @doc """
  Optional: caps the exchanges made with `state` at `deadline`, an absolute
  `System.monotonic_time(:millisecond)`, or removes the cap when `deadline`
  is `nil`.

  ExMCP sets a deadline while it establishes the connection, around the
  `send_message/2` of a request whose caller gave a timeout (restoring the
  previous value, read with `deadline/1`, as soon as that call returns), and
  before `close/1`, which is given `ExMCP.Client`'s cleanup budget of one
  second. A transport that exchanges synchronously in `send_message/2`
  bounds that exchange by the deadline; one that hands the exchange to
  another process reads the deadline in `send_message/2` and carries it
  along.

  Implement it together with `deadline/1`. Without them the transport is
  bounded only by its own timeouts.
  """
  @callback put_deadline(state(), deadline :: integer() | nil) :: state()

  @doc """
  Optional: the deadline last set with `put_deadline/2`, or `nil`.
  """
  @callback deadline(state()) :: integer() | nil

  @doc """
  Optional: adopts the protocol version the server selected in the
  `initialize` handshake.

  ExMCP calls it as soon as the `initialize` result arrives, before it sends
  `notifications/initialized`, so a transport that carries the version on
  every message it sends (Streamable HTTP's `MCP-Protocol-Version` header)
  sends the negotiated one from that notification on.
  """
  @callback set_protocol_version(state(), version :: String.t()) :: state()

  @doc """
  Optional: gives up on the response to `request_id`.

  `ExMCP.Client` calls it when a request it sent through this transport
  times out: the caller has been answered with `{:error, :timeout}`, and a
  response that arrives later is dropped. The transport releases what it
  holds for the request, such as an open response stream. The client does
  not send `notifications/cancelled` for a timed-out request; a transport
  that should stop the server's work sends it from here. (A cancellation the
  caller asks for with `ExMCP.Client.send_cancelled/3` reaches the transport
  as that notification, through `send_message/2`.)
  """
  @callback cancel_request(state(), request_id :: ExMCP.Types.request_id()) :: state()

  @optional_callbacks connected?: 1,
                      capabilities: 1,
                      subscribe: 2,
                      linked_processes: 1,
                      put_deadline: 2,
                      deadline: 1,
                      set_protocol_version: 2,
                      cancel_request: 2

  @doc """
  Check if a transport module supports the push (subscribe) model.
  """
  @spec supports_push?(module()) :: boolean()
  def supports_push?(transport_mod) do
    function_exported?(transport_mod, :subscribe, 2)
  end

  @doc """
  Returns the processes and ports `transport_mod` linked to its caller for
  `transport_state`, or `[]` when the transport does not say.
  """
  @spec linked_processes(module() | nil, state()) :: [pid() | port()]
  def linked_processes(nil, _transport_state), do: []
  def linked_processes(_transport_mod, nil), do: []

  def linked_processes(transport_mod, transport_state) do
    if function_exported?(transport_mod, :linked_processes, 1) do
      transport_state
      |> transport_mod.linked_processes()
      |> Enum.filter(&(is_pid(&1) or is_port(&1)))
    else
      []
    end
  rescue
    _error -> []
  end

  @doc """
  Helper to get the appropriate transport module for an atom identifier.

  ## Transport identifiers:
  - `:stdio` - Standard I/O transport (official MCP transport)
  - `:http` - Streamable HTTP transport with SSE (official MCP transport)
  - `:sse` - Deprecated MCP 2024-11-05 HTTP+SSE (`GET /sse` + `POST /message`)
  - `:test` - In-memory transport for testing (non-standard)
  - `:beam` - BEAM-local transport carrying MCP-shaped messages as Elixir terms.
  """
  @spec get_transport(:stdio | :http | :sse | :test | :beam | module()) :: module()
  def get_transport(:stdio), do: ExMCP.Transport.Stdio
  def get_transport(:http), do: ExMCP.Transport.HTTP
  def get_transport(:sse), do: ExMCP.Transport.HTTP.LegacySSE
  def get_transport(:test), do: ExMCP.Transport.Test
  def get_transport(:beam), do: ExMCP.Transport.Local
  def get_transport(module) when is_atom(module), do: module
end
