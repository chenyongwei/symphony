defmodule SymphonyElixir.Workpad do
  @moduledoc """
  Helpers for recognizing and validating Symphony workpad comments.
  """

  @marker "## Codex Workpad"
  @base_sections [
    "### Plan",
    "### Acceptance Criteria",
    "### Validation",
    "### Notes"
  ]

  @gated_sections [
    "### Plan Review Gate",
    "### Evidence"
  ]

  @gate_status_values ~w(drafting-plan pending-human-review approved-for-implementation)

  @spec workpad_comment?(String.t() | nil) :: boolean()
  def workpad_comment?(body) when is_binary(body) do
    Regex.match?(~r/^\s*#{Regex.escape(@marker)}\b/m, body)
  end

  def workpad_comment?(_body), do: false

  @spec validate(String.t(), keyword()) :: :ok | {:error, [String.t()]}
  def validate(body, opts \\ []) when is_binary(body) do
    errors =
      []
      |> require_marker(body)
      |> require_environment_stamp(body)
      |> require_sections(body, @base_sections)
      |> maybe_require_gated_sections(body, Keyword.get(opts, :plan_gate_required, false))
      |> maybe_require_valid_gate_status(body, Keyword.get(opts, :plan_gate_required, false))

    if errors == [] do
      :ok
    else
      {:error, errors}
    end
  end

  defp require_marker(errors, body) do
    if workpad_comment?(body) do
      errors
    else
      errors ++ ["Workpad comment must start with `## Codex Workpad`."]
    end
  end

  defp require_environment_stamp(errors, body) do
    if Regex.match?(~r/##\s+Codex Workpad[\s\S]*?```text\s*\n[\s\S]+?\n```/m, body) do
      errors
    else
      errors ++ ["Workpad comment must include the environment stamp code fence directly under the header."]
    end
  end

  defp require_sections(errors, body, sections) when is_list(sections) do
    missing =
      Enum.reject(sections, fn section ->
        String.contains?(body, section)
      end)

    errors ++ Enum.map(missing, &"Workpad comment is missing required section: #{&1}")
  end

  defp maybe_require_gated_sections(errors, _body, false), do: errors

  defp maybe_require_gated_sections(errors, body, true) do
    require_sections(errors, body, @gated_sections)
  end

  defp maybe_require_valid_gate_status(errors, _body, false), do: errors

  defp maybe_require_valid_gate_status(errors, body, true) do
    if Regex.match?(
         ~r/###\s+Plan Review Gate[\s\S]*?-\s+Gate status:\s+`(drafting-plan|pending-human-review|approved-for-implementation)`/m,
         body
       ) do
      errors
    else
      errors ++
        [
          "Workpad comment must include `- Gate status: `<#{Enum.join(@gate_status_values, "|")}>`` inside `### Plan Review Gate`."
        ]
    end
  end
end
