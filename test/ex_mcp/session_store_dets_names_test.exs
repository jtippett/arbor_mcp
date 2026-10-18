defmodule ExMCP.SessionStoreDETSNamesTest do
  # Measures the node-wide atom count, so it must not run beside async tests.
  use ExUnit.Case, async: false

  alias ExMCP.Internal.SessionStore.DETS

  setup do
    path = Path.join(System.tmp_dir!(), "ex_mcp-dets-names-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "repeated durable reopen retains all tables without permanent atom allocation", %{
    path: path
  } do
    {:ok, store} = DETS.open(%{storage_path: path})
    assert Enum.all?(store.names, &is_reference/1)
    assert DETS.insert(store, :sessions, {"session", %{initialized: true}})
    assert DETS.insert(store, :events, {{"session", 1}, %{data: "committed"}})
    assert DETS.insert_new(store, :request_ids, {{"session", 1}, :claimed})
    DETS.put_event_clock(store, 11)
    :ok = DETS.close(store)

    # Warm the reopen path before measuring global atom count.
    {:ok, reopened} = DETS.open(%{storage_path: path})
    :ok = DETS.close(reopened)
    initial_atoms = :erlang.system_info(:atom_count)

    for _ <- 1..64 do
      {:ok, reopened} = DETS.open(%{storage_path: path})
      assert Enum.all?(reopened.names, &is_reference/1)
      assert [{"session", %{initialized: true}}] = DETS.lookup(reopened, :sessions, "session")

      assert [{{"session", 1}, %{data: "committed"}}] =
               DETS.lookup(reopened, :events, {"session", 1})

      assert [{{"session", 1}, :claimed}] = DETS.lookup(reopened, :request_ids, {"session", 1})
      assert DETS.event_clock(reopened) == 11
      :ok = DETS.close(reopened)
    end

    assert :erlang.system_info(:atom_count) == initial_atoms
  end

  test "a concurrent opener cannot alias or close another owner's files", %{path: path} do
    {:ok, store} = DETS.open(%{storage_path: path})
    DETS.insert(store, :sessions, {"session", %{initialized: true}})
    parent = self()

    spawn(fn -> send(parent, {:second_open, DETS.open(%{storage_path: path})}) end)
    assert_receive {:second_open, {:error, :storage_in_use}}, 1_000
    assert [{"session", %{initialized: true}}] = DETS.lookup(store, :sessions, "session")
    :ok = DETS.close(store)
  end

  # Stores written before this change opened the same files under atom table
  # names (:"ex_mcp_session_dets_<n>_<table>"). DETS keeps no table name in
  # the file, so an upgraded node must reopen those files unchanged.
  test "files written under the previous atom table names reopen after upgrade", %{
    path: path
  } do
    File.mkdir_p!(path)
    suffix = System.unique_integer([:positive])

    previous = [
      sessions: {"session", %{initialized: true}},
      events: {{"session", 1}, %{data: "committed"}},
      request_ids: {{"session", 1}, :claimed},
      meta: {:event_clock, 11}
    ]

    for {table, object} <- previous do
      name = :"ex_mcp_session_dets_#{suffix}_#{table}"

      {:ok, ^name} =
        :dets.open_file(name,
          file: String.to_charlist(Path.join(path, "#{table}.dets")),
          type: :set,
          access: :read_write,
          auto_save: :infinity,
          repair: true
        )

      :ok = :dets.insert(name, object)
      :ok = :dets.close(name)
    end

    assert {:ok, store} = DETS.open(%{storage_path: path})
    assert [{"session", %{initialized: true}}] = DETS.lookup(store, :sessions, "session")
    assert [{{"session", 1}, %{data: "committed"}}] = DETS.lookup(store, :events, {"session", 1})
    assert [{{"session", 1}, :claimed}] = DETS.lookup(store, :request_ids, {"session", 1})
    assert DETS.event_clock(store) == 11
    :ok = DETS.close(store)

    assert Enum.sort(File.ls!(path)) ==
             ["events.dets", "meta.dets", "request_ids.dets", "sessions.dets"]
  end
end
