defmodule ExMCP.Server.StructuredContentWireTest do
  @moduledoc """
  Structured tool results reach the wire under the canonical MCP
  `structuredContent` field, even when the handler (notably the deprecated
  `ExMCP.Server.Tools` API) produces the `structuredOutput` alias.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Plug.Conn
  import Plug.Test

  alias ExMCP.HttpPlug
  alias ExMCP.Server.{Dispatch, ResultNormalizer}
  alias ExMCP.SessionManager

  defmodule RawHandler do
    use ExMCP.Server.Handler

    @impl true
    def init(_args), do: {:ok, %{}}

    @impl true
    def handle_call_tool("alias_only", _args, state) do
      {:ok, %{content: [], structuredOutput: %{value: 1}}, state}
    end

    def handle_call_tool("both", _args, state) do
      {:ok,
       %{
         "content" => [],
         "structuredContent" => %{"value" => "canonical"},
         "structuredOutput" => %{"value" => "alias"}
       }, state}
    end
  end

  setup_all do
    # The deprecated Tools API warns at compile time; keep the test output clean.
    capture_io(:stderr, fn ->
      defmodule DeprecatedToolsServer do
        use ExMCP.Server.Handler
        use ExMCP.Server.Tools

        tool "weather" do
          description("Weather with structured output")
          input_schema(%{type: "object", properties: %{}})

          handle(fn _args, state ->
            {:ok,
             %{
               content: [%{type: "text", text: "Sunny"}],
               structuredContent: %{temperature: 21, conditions: "sunny"}
             }, state}
          end)
        end
      end
    end)

    :ok
  end

  defp tools_server, do: Module.concat(__MODULE__, DeprecatedToolsServer)

  defp call_request(name, id \\ 1) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}}
    }
  end

  test "the deprecated Tools API keeps its public structuredOutput result" do
    assert {:ok, result, _state} = tools_server().handle_call_tool("weather", %{}, %{})
    assert result.structuredOutput == %{temperature: 21, conditions: "sunny"}
  end

  test "handler-process and stdio dispatch emit structuredContent for the Tools API" do
    {:ok, state} = tools_server().init([])

    assert {:response, %{"result" => result}, _state} =
             Dispatch.dispatch(call_request("weather"), tools_server(), state)

    wire = result |> Jason.encode!() |> Jason.decode!()
    assert wire["structuredContent"] == %{"temperature" => 21, "conditions" => "sunny"}
    refute Map.has_key?(wire, "structuredOutput")
    assert wire["content"] == [%{"type" => "text", "text" => "Sunny"}]
  end

  test "HTTP emits structuredContent for the Tools API and raw handler aliases" do
    for {handler, name, expected} <- [
          {tools_server(), "weather", %{"temperature" => 21, "conditions" => "sunny"}},
          {RawHandler, "alias_only", %{"value" => 1}},
          {RawHandler, "both", %{"value" => "canonical"}}
        ] do
      session_id = SessionManager.create_session(%{transport: :http})
      :ok = SessionManager.claim_initialization(session_id)
      :ok = SessionManager.complete_initialization(session_id, "2025-06-18")
      on_exit(fn -> SessionManager.terminate_session(session_id) end)

      conn =
        conn(:post, "/", Jason.encode!(call_request(name)))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> HttpPlug.call(HttpPlug.init(handler: handler, sse_enabled: false))

      assert conn.status == 200, conn.resp_body
      result = Jason.decode!(conn.resp_body)["result"]
      assert result["structuredContent"] == expected, inspect({name, result})
      refute Map.has_key?(result, "structuredOutput")
    end
  end

  test "protocol_result canonicalizes only tools/call results in both eras" do
    alias_result = %{content: [], structuredOutput: %{value: 1}}

    legacy = ResultNormalizer.protocol_result(alias_result, %{era: :legacy, method: "tools/call"})
    assert legacy == %{"content" => [], "structuredContent" => %{"value" => 1}}

    modern =
      ResultNormalizer.protocol_result(alias_result, %{era: :modern, method: "tools/call"},
        server_info: %{name: "example", version: "1"}
      )

    assert modern["structuredContent"] == %{"value" => 1}
    assert modern["resultType"] == "complete"
    refute Map.has_key?(modern, "structuredOutput")

    canonical = %{"content" => [], "structuredContent" => %{"value" => 2}}

    assert ResultNormalizer.protocol_result(canonical, %{era: :legacy, method: "tools/call"}) ==
             canonical

    # Other methods are untouched.
    assert ResultNormalizer.protocol_result(alias_result, %{era: :legacy, method: "prompts/get"}) ==
             alias_result
  end
end
