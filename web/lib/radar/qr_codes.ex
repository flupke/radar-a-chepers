defmodule Radar.QrCodes do
  @moduledoc """
  Utility module for generating QR codes that link to infraction details.
  """

  @doc """
  Generates a QR code PNG image data for an infraction.
  Returns the binary PNG data that can be served directly or saved to file.
  """
  def generate_infraction_qr(infraction_id) do
    url = generate_infraction_url(infraction_id)

    case QRCode.create(url) do
      {:ok, qr_code} ->
        {:ok, QRCode.render(qr_code)}

      {:error, reason} ->
        {:error, "Failed to generate QR code: #{reason}"}
    end
  end

  @doc """
  Generates a QR code as base64 string for an infraction.
  Returns base64 encoded QR code that can be embedded in HTML as data URI.
  """
  def generate_infraction_qr_base64(infraction_id) do
    url = generate_infraction_url(infraction_id)

    case QRCode.create(url) do
      {:ok, qr_code} ->
        base64_data = QRCode.to_base64(qr_code)
        {:ok, base64_data}

      {:error, reason} ->
        {:error, "Failed to generate QR code: #{reason}"}
    end
  end

  @doc """
  Generates a QR code SVG string for an infraction.
  Returns SVG markup that can be embedded in HTML.
  """
  def generate_infraction_qr_svg(infraction_id) do
    url = generate_infraction_url(infraction_id)

    case QRCode.create(url) do
      {:ok, qr_code} ->
        {:ok, QRCode.render(qr_code, :svg)}

      {:error, reason} ->
        {:error, "Failed to generate QR code: #{reason}"}
    end
  end

  @doc """
  Generates the URL that the QR code should link to for a given infraction.
  """
  def generate_infraction_url(infraction_id) do
    base_url = get_base_url()
    "#{base_url}/infractions/#{infraction_id}"
  end

  defp get_base_url do
    # For development, use localhost. In production, this would come from config
    Application.get_env(:radar, :base_url, "http://localhost:4000")
  end
end
