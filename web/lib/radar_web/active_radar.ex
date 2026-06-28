defmodule RadarWeb.ActiveRadar do
  @moduledoc false

  use GenServer

  defstruct [:pid, :monitor_ref, :device_type, :test_mode]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def register(pid, device_type, test_mode) when is_pid(pid) do
    GenServer.call(__MODULE__, {:register, pid, device_type, test_mode})
  end

  def unregister(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:unregister, pid})
  end

  def current do
    GenServer.call(__MODULE__, :current)
  end

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_call(:current, _from, nil), do: {:reply, nil, nil}

  def handle_call(:current, _from, state) do
    if Process.alive?(state.pid) do
      {:reply, active_radar(state), state}
    else
      Process.demonitor(state.monitor_ref, [:flush])
      {:reply, nil, nil}
    end
  end

  def handle_call({:register, pid, device_type, test_mode}, _from, nil) do
    {:reply, :ok, track(pid, device_type, test_mode)}
  end

  def handle_call({:register, pid, device_type, test_mode}, _from, %{pid: pid} = state) do
    if state.device_type == device_type and state.test_mode == test_mode do
      {:reply, :ok, state}
    else
      {:reply, {:error, :device_already_connected}, state}
    end
  end

  def handle_call({:register, pid, device_type, test_mode}, _from, state) do
    if Process.alive?(state.pid) do
      {:reply, {:error, :device_already_connected}, state}
    else
      Process.demonitor(state.monitor_ref, [:flush])
      {:reply, :ok, track(pid, device_type, test_mode)}
    end
  end

  def handle_call({:unregister, pid}, _from, %{pid: pid, monitor_ref: monitor_ref}) do
    Process.demonitor(monitor_ref, [:flush])
    {:reply, :ok, nil}
  end

  def handle_call({:unregister, _pid}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, pid, _reason}, %{
        pid: pid,
        monitor_ref: monitor_ref
      }) do
    {:noreply, nil}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp active_radar(state) do
    %{
      device_type: state.device_type,
      test_mode: state.test_mode
    }
  end

  defp track(pid, device_type, test_mode) do
    %__MODULE__{
      pid: pid,
      monitor_ref: Process.monitor(pid),
      device_type: device_type,
      test_mode: test_mode
    }
  end
end
