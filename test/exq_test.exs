Code.require_file "test_helper.exs", __DIR__


defmodule ExqTest do
  use ExUnit.Case
  import ExqTestUtil

  defmodule PerformWorker do
    def perform do
      send :exqtest, {:worked}
    end
  end

  defmodule PerformArgWorker do
    def perform(arg) do
      send :exqtest, {:worked, arg}
    end
  end

  defmodule CustomMethodWorker do
    def simple_perform do
    end
  end

  defmodule MissingMethodWorker do
  end

  defmodule FailWorker do
    def failure_perform do
      :num + 1
      send :exqtest, {:worked}
    end
  end

  setup do
    TestRedis.start
    on_exit fn ->
      wait
      TestRedis.stop
    end
    :ok
  end

  test "start using registered name" do
    {:ok, exq_sup} = Exq.start_link([port: 6555, name: :custom_manager, namespace: "test"])
    assert_exq_up(:custom_manager)
    stop_process(exq_sup)
  end

  test "start multiple exq instances using registered name" do
    {:ok, sup1} = Exq.start_link([port: 6555, name: :custom_manager1, namespace: "test"])
    assert_exq_up(:custom_manager1)

    {:ok, sup2} = Exq.start_link([port: 6555, name: :custom_manager2, namespace: "test"])
    assert_exq_up(:custom_manager2)

    stop_process(sup1)
    stop_process(sup2)
  end

  test "enqueue and run job" do
    Process.register(self, :exqtest)
    {:ok, sup} = Exq.start_link([name: :exq_t, port: 6555, namespace: "test"])
    {:ok, _} = Exq.enqueue(:exq_t, "default", "ExqTest.PerformWorker", [])
    wait
    assert_received {:worked}
    stop_process(sup)
  end

  test "enqueue with separate enqueuer" do
    Process.register(self, :exqtest)
    {:ok, exq_sup} = Exq.start_link([name: :exq_t, port: 6555, namespace: "test"])
    {:ok, enq_sup} = Exq.Enqueuer.start_link([name: :exq_e, port: 6555, namespace: "test"])
    {:ok, _} = Exq.Enqueuer.enqueue(:exq_e, "default", "ExqTest.PerformWorker", [])
    wait_long
    assert_received {:worked}
    stop_process(exq_sup)
    stop_process(enq_sup)
  end


  test "run jobs on multiple queues" do
    Process.register(self, :exqtest)
    {:ok, sup} = Exq.start_link([name: :exq_t, port: 6555, namespace: "test", queues: ["q1", "q2"]])
    {:ok, _} = Exq.enqueue(:exq_t, "q1", "ExqTest.PerformArgWorker", [1])
    {:ok, _} = Exq.enqueue(:exq_t, "q2", "ExqTest.PerformArgWorker", [2])
    wait_long
    assert_received {:worked, 1}
    assert_received {:worked, 2}
    stop_process(sup)
  end

  test "record processed jobs" do
    {:ok, sup} = Exq.start_link([name: :exq_t, port: 6555, namespace: "test"])
    state = :sys.get_state(:exq_t)

    {:ok, jid} = Exq.enqueue(:exq_t, "default", "ExqTest.CustomMethodWorker/simple_perform", [])
    wait
    {:ok, count} = TestStats.processed_count(state.redis, "test")
    assert count == "1"

    {:ok, jid} = Exq.enqueue(:exq_t, "default", "ExqTest.CustomMethodWorker/simple_perform", [])
    wait_long
    {:ok, count} = TestStats.processed_count(state.redis, "test")
    assert count == "2"

    stop_process(sup)
  end

  test "record failed jobs" do
    {:ok, sup} = Exq.start_link([name: :exq_t, port: 6555, namespace: "test"])
    state = :sys.get_state(:exq_t)

    {:ok, jid} = Exq.enqueue(:exq_t, "default", "ExqTest.MissingMethodWorker/fail", [])
    wait_long
    {:ok, count} = TestStats.failed_count(state.redis, "test")
    assert count == "1"

    {:ok, jid} = Exq.enqueue(:exq_t, "default", "ExqTest.MissingWorker", [])
    wait_long
    {:ok, count} = TestStats.failed_count(state.redis, "test")
    assert count == "2"


    {:ok, jid} = Exq.enqueue(:exq_t, "default", "ExqTest.FailWorker/failure_perform", [])

    # if we kill Exq too fast we dont record the failure because exq is gone
    wait_long

    {:ok, enq_sup} = Exq.Enqueuer.start_link([name: :exq_e, port: 6555, namespace: "test"])

    # Find the job in the processed queue
    {:ok, job, idx} = Exq.Api.find_failed(:exq_e, jid)

    wait_long

    stop_process(sup)
    stop_process(enq_sup)
  end
end
