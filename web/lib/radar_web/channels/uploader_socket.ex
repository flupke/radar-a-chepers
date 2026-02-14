defmodule RadarWeb.UploaderSocket do
  use Phoenix.Socket

  channel "radar:*", RadarWeb.RadarConfigChannel

  @impl true
  def connect(%{"api_key" => api_key}, socket, _connect_info) do
    if api_key in configured_api_keys() do
      {:ok, socket}
    else
      :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: "uploader_socket"

  defp configured_api_keys do
    Application.get_env(:radar, :api_keys)
  end
end
