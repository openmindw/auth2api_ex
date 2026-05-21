defmodule Auth2ApiEx.AuditLogTest do
  use ExUnit.Case, async: false

  alias Auth2ApiEx.AuditLog

  setup do
    # Clear state before each test (AuditLog uses a singleton GenServer + named ETS table)
    AuditLog.clear()
    %{}
  end

  describe "record/1 and list/1" do
    test "auto-generates id and timestamp" do
      AuditLog.record(%{method: "POST", path: "ChatCompletions", status: 200})
      Process.sleep(20)

      logs = AuditLog.list(limit: 1)
      assert length(logs) == 1
      log = hd(logs)
      assert is_integer(log.id) and log.id > 0
      assert is_binary(log.timestamp)
      assert log.method == "POST"
      assert log.path == "ChatCompletions"
      assert log.status == 200
    end

    test "increments id counter" do
      AuditLog.record(%{path: "A", status: 200})
      AuditLog.record(%{path: "B", status: 200})
      Process.sleep(20)

      logs = AuditLog.list(limit: 10)
      ids = Enum.map(logs, & &1.id)
      assert length(ids) == 2
      assert Enum.at(ids, 0) > Enum.at(ids, 1)
    end

    test "returns newest first" do
      AuditLog.record(%{path: "A", status: 200})
      AuditLog.record(%{path: "B", status: 200})
      AuditLog.record(%{path: "C", status: 200})
      Process.sleep(20)

      logs = AuditLog.list()
      paths = Enum.map(logs, & &1.path)
      assert paths == ["C", "B", "A"]
    end

    test "respects limit" do
      for i <- 1..10, do: AuditLog.record(%{path: "#{i}", status: 200})
      Process.sleep(50)

      logs = AuditLog.list(limit: 3)
      assert length(logs) == 3
    end

    test "respects offset" do
      for i <- 1..5, do: AuditLog.record(%{path: "#{i}", status: 200})
      Process.sleep(50)

      logs = AuditLog.list(limit: 2, offset: 2)
      assert length(logs) == 2
      paths = Enum.map(logs, & &1.path)
      assert paths == ["3", "2"]
    end

    test "filters by status :2xx" do
      AuditLog.record(%{path: "ok", status: 200})
      AuditLog.record(%{path: "err", status: 500})
      Process.sleep(20)

      logs = AuditLog.list(status: :"2xx")
      assert length(logs) == 1
      assert hd(logs).path == "ok"
    end

    test "filters by status :4xx" do
      AuditLog.record(%{path: "bad", status: 400})
      AuditLog.record(%{path: "ok", status: 200})
      Process.sleep(20)

      logs = AuditLog.list(status: :"4xx")
      assert length(logs) == 1
      assert hd(logs).path == "bad"
    end

    test "filters by status :5xx" do
      AuditLog.record(%{path: "crash", status: 502})
      AuditLog.record(%{path: "ok", status: 200})
      Process.sleep(20)

      logs = AuditLog.list(status: :"5xx")
      assert length(logs) == 1
      assert hd(logs).path == "crash"
    end
  end

  describe "eviction" do
    test "evicts oldest records when exceeding 500" do
      for i <- 1..510 do
        AuditLog.record(%{path: "#{i}", status: 200})
      end

      Process.sleep(500)

      count = AuditLog.count()
      assert count <= 500
    end
  end

  describe "clear/0" do
    test "clears all records and resets counter" do
      AuditLog.record(%{path: "A", status: 200})
      AuditLog.record(%{path: "B", status: 200})
      Process.sleep(20)

      assert AuditLog.count() == 2

      AuditLog.clear()

      assert AuditLog.count() == 0
      assert AuditLog.list() == []

      # After clear, new records should start fresh
      AuditLog.record(%{path: "fresh", status: 200})
      Process.sleep(20)
      logs = AuditLog.list()
      assert length(logs) == 1
      assert hd(logs).path == "fresh"
    end
  end

  describe "count/0" do
    test "returns number of records" do
      assert AuditLog.count() == 0
      AuditLog.record(%{path: "A", status: 200})
      AuditLog.record(%{path: "B", status: 400})
      Process.sleep(20)
      assert AuditLog.count() == 2
    end
  end
end
