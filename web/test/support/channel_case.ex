defmodule RadarWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by channel tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint RadarWeb.Endpoint

      import Phoenix.ChannelTest
    end
  end

  setup tags do
    Radar.DataCase.setup_sandbox(tags)
    :ok
  end
end
