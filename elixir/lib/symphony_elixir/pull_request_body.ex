defmodule SymphonyElixir.PullRequestBody do
  @moduledoc """
  Validates pull request bodies against the repository PR template.
  """

  @template_paths [
    ".github/pull_request_template.md",
    "../.github/pull_request_template.md"
  ]

  @type validation_error :: String.t()

  @spec validate_body(String.t(), Path.t()) ::
          :ok | {:error, {:template_not_found, [String.t()]}} | {:error, {:invalid, String.t(), [validation_error()]}}
  def validate_body(body, repo_root) when is_binary(body) and is_binary(repo_root) do
    with {:ok, template_path, template} <- read_template(repo_root),
         {:ok, headings} <- extract_template_headings(template, template_path),
         [] <- lint(template, body, headings) do
      :ok
    else
      {:error, reason} ->
        {:error, reason}

      errors when is_list(errors) ->
        with {:ok, template_path, _template} <- read_template(repo_root) do
          {:error, {:invalid, template_path, errors}}
        end
    end
  end

  @spec validate_file(Path.t(), Path.t()) ::
          :ok
          | {:error, {:read_failed, Path.t(), term()}}
          | {:error, {:template_not_found, [String.t()]}}
          | {:error, {:invalid, String.t(), [validation_error()]}}
  def validate_file(file_path, repo_root) when is_binary(file_path) and is_binary(repo_root) do
    case File.read(file_path) do
      {:ok, body} ->
        validate_body(body, repo_root)

      {:error, reason} ->
        {:error, {:read_failed, file_path, reason}}
    end
  end

  defp read_template(repo_root) do
    case Enum.find_value(@template_paths, &read_template_candidate(repo_root, &1)) do
      {:ok, _path, _template} = result ->
        result

      nil ->
        {:error, {:template_not_found, @template_paths}}
    end
  end

  defp read_template_candidate(repo_root, relative_path) do
    template_path = Path.join(repo_root, relative_path)

    case File.read(template_path) do
      {:ok, content} -> {:ok, template_path, content}
      {:error, _reason} -> nil
    end
  end

  defp extract_template_headings(template, template_path) do
    headings =
      Regex.scan(~r/^\#{4,6}\s+.+$/m, template)
      |> Enum.map(&hd/1)

    if headings == [] do
      {:error, {:invalid, template_path, ["No markdown headings found in #{template_path}"]}}
    else
      {:ok, headings}
    end
  end

  defp lint(template, body, headings) do
    []
    |> check_required_headings(body, headings)
    |> check_order(body, headings)
    |> check_no_placeholders(body)
    |> check_sections_from_template(template, body, headings)
  end

  defp check_required_headings(errors, body, headings) do
    missing = Enum.filter(headings, fn heading -> heading_position(body, heading) == :nomatch end)
    errors ++ Enum.map(missing, fn heading -> "Missing required heading: #{heading}" end)
  end

  defp check_order(errors, body, headings) do
    positions =
      headings
      |> Enum.map(&heading_position(body, &1))
      |> Enum.reject(&(&1 == :nomatch))

    if positions == Enum.sort(positions), do: errors, else: errors ++ ["Required headings are out of order."]
  end

  defp check_no_placeholders(errors, body) do
    if String.contains?(body, "<!--") do
      errors ++ ["PR description still contains template placeholder comments (<!-- ... -->)."]
    else
      errors
    end
  end

  defp check_sections_from_template(errors, template, body, headings) do
    Enum.reduce(headings, errors, fn heading, acc ->
      template_section = capture_heading_section(template, heading, headings)
      body_section = capture_heading_section(body, heading, headings)

      cond do
        is_nil(body_section) ->
          acc

        String.trim(body_section) == "" ->
          acc ++ ["Section cannot be empty: #{heading}"]

        true ->
          acc
          |> maybe_require_bullets(heading, template_section, body_section)
          |> maybe_require_checkboxes(heading, template_section, body_section)
      end
    end)
  end

  defp maybe_require_bullets(errors, heading, template_section, body_section) do
    requires_bullets = Regex.match?(~r/^- /m, template_section || "")

    if requires_bullets and not Regex.match?(~r/^- /m, body_section) do
      errors ++ ["Section must include at least one bullet item: #{heading}"]
    else
      errors
    end
  end

  defp maybe_require_checkboxes(errors, heading, template_section, body_section) do
    requires_checkboxes = Regex.match?(~r/^- \[ \] /m, template_section || "")

    if requires_checkboxes and not Regex.match?(~r/^- \[[ xX]\] /m, body_section) do
      errors ++ ["Section must include at least one checkbox item: #{heading}"]
    else
      errors
    end
  end

  defp heading_position(body, heading) do
    case :binary.match(body, heading) do
      {idx, _len} -> idx
      :nomatch -> :nomatch
    end
  end

  defp capture_heading_section(doc, heading, headings) do
    with {heading_idx, _} <- :binary.match(doc, heading),
         section_start <- heading_idx + byte_size(heading),
         true <- section_start + 2 <= byte_size(doc),
         "\n\n" <- binary_part(doc, section_start, 2) do
      extract_section_content(doc, section_start + 2, heading, headings)
    else
      :nomatch -> nil
      false -> ""
      _ -> nil
    end
  end

  defp extract_section_content(doc, content_start, heading, headings) do
    content = binary_part(doc, content_start, byte_size(doc) - content_start)

    case next_heading_offset(content, heading, headings) do
      nil -> content
      offset -> binary_part(content, 0, offset)
    end
  end

  defp next_heading_offset(content, heading, headings) do
    headings_after(heading, headings)
    |> Enum.map(fn marker -> :binary.match(content, marker) end)
    |> Enum.filter(&(&1 != :nomatch))
    |> Enum.map(fn {idx, _} -> idx end)
    |> case do
      [] -> nil
      indexes -> Enum.min(indexes)
    end
  end

  defp headings_after(current_heading, headings) do
    headings
    |> Enum.filter(&(&1 != current_heading))
    |> Enum.map(&("\n" <> &1))
  end
end
