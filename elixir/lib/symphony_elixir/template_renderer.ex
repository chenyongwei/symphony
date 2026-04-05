defmodule SymphonyElixir.TemplateRenderer do
  @moduledoc """
  Shared Solid template rendering helpers for workflow prompt and command templates.
  """

  @render_opts [strict_variables: true, strict_filters: true]

  @spec render!(String.t(), map()) :: String.t()
  def render!(template, assigns) when is_binary(template) and is_map(assigns) do
    template
    |> parse_template!()
    |> Solid.render!(to_solid_map(assigns), @render_opts)
    |> IO.iodata_to_binary()
  end

  @spec to_solid_map(map()) :: map()
  def to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp parse_template!(template) when is_binary(template) do
    Solid.parse!(template)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(template)}"
              },
              __STACKTRACE__
  end
end
