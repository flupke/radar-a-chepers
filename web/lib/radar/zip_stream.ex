defmodule Radar.ZipStream do
  @moduledoc false

  @max_uint32 0xFFFF_FFFF
  @version_needed 20
  @general_purpose_flag 0x0008
  @compression_method 0
  @dos_time 0
  @dos_date 0

  def send(conn, entries) do
    entries
    |> Enum.reduce_while({:ok, initial_state(conn)}, fn entry, {:ok, state} ->
      case send_entry(state, entry) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, state} -> send_central_directory(state)
      {:error, reason} -> {:error, reason}
    end
  end

  defp initial_state(conn) do
    %{conn: conn, offset: 0, central_directory: [], entry_count: 0}
  end

  defp send_entry(state, %{name: name, stream: stream, size: size})
       when is_integer(size) and size <= @max_uint32 do
    filename = IO.iodata_to_binary(name)
    local_header_offset = state.offset

    with {:ok, state} <- send_chunk(state, local_file_header(filename)),
         {:ok, state, crc32, size} <- send_entry_stream(state, stream),
         {:ok, state} <- send_chunk(state, data_descriptor(crc32, size)) do
      central_directory_entry =
        central_directory_header(filename, crc32, size, local_header_offset)

      {:ok,
       %{
         state
         | central_directory: [central_directory_entry | state.central_directory],
           entry_count: state.entry_count + 1
       }}
    end
  end

  defp send_entry(state, _entry), do: {:ok, state}

  defp send_entry_stream(state, stream) do
    stream
    |> Enum.reduce_while({:ok, state, 0, 0}, fn chunk, {:ok, state, crc32, size} ->
      chunk = IO.iodata_to_binary(chunk)
      chunk_size = byte_size(chunk)

      if size + chunk_size > @max_uint32 do
        {:halt, {:error, :zip_entry_too_large}}
      else
        case send_chunk(state, chunk) do
          {:ok, state} ->
            {:cont, {:ok, state, :erlang.crc32(crc32, chunk), size + chunk_size}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp send_central_directory(state) do
    central_directory = state.central_directory |> Enum.reverse()
    central_directory_offset = state.offset
    central_directory_size = IO.iodata_length(central_directory)

    end_record =
      end_of_central_directory(
        state.entry_count,
        central_directory_size,
        central_directory_offset
      )

    with {:ok, state} <- send_chunk(state, central_directory),
         {:ok, state} <- send_chunk(state, end_record) do
      {:ok, state.conn}
    end
  end

  defp send_chunk(state, []), do: {:ok, state}

  defp send_chunk(state, chunk) do
    case Plug.Conn.chunk(state.conn, chunk) do
      {:ok, conn} -> {:ok, %{state | conn: conn, offset: state.offset + IO.iodata_length(chunk)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp local_file_header(filename) do
    [
      <<0x04034B50::little-32, @version_needed::little-16, @general_purpose_flag::little-16,
        @compression_method::little-16, @dos_time::little-16, @dos_date::little-16, 0::little-32,
        0::little-32, 0::little-32, byte_size(filename)::little-16, 0::little-16>>,
      filename
    ]
  end

  defp data_descriptor(crc32, size) do
    <<0x08074B50::little-32, crc32::little-32, size::little-32, size::little-32>>
  end

  defp central_directory_header(filename, crc32, size, local_header_offset) do
    [
      <<0x02014B50::little-32, @version_needed::little-16, @version_needed::little-16,
        @general_purpose_flag::little-16, @compression_method::little-16, @dos_time::little-16,
        @dos_date::little-16, crc32::little-32, size::little-32, size::little-32,
        byte_size(filename)::little-16, 0::little-16, 0::little-16, 0::little-16, 0::little-16,
        0::little-32, local_header_offset::little-32>>,
      filename
    ]
  end

  defp end_of_central_directory(entry_count, central_directory_size, central_directory_offset) do
    <<0x06054B50::little-32, 0::little-16, 0::little-16, entry_count::little-16,
      entry_count::little-16, central_directory_size::little-32,
      central_directory_offset::little-32, 0::little-16>>
  end
end
